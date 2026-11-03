"""Constrained output-layer tuning plus validation-only class calibration.

The feature extractor, hidden layers, and traffic-class output columns remain
bit-identical to V1. Softmax coupling can still change traffic probabilities;
therefore validation regression guards are also required.
"""
import os
os.environ['OPENBLAS_NUM_THREADS']='2'
os.environ['OMP_NUM_THREADS']='2'
from pathlib import Path
import copy,csv,json,shutil,subprocess,sys,time
from dataclasses import asdict
from types import SimpleNamespace
import joblib,numpy as np
from scipy.optimize import minimize
from scipy.special import logsumexp,softmax
from sklearn.metrics import confusion_matrix,classification_report,accuracy_score,f1_score
from sklearn.utils.class_weight import compute_sample_weight
from threadpoolctl import threadpool_limits

import argparse
import model_io as exporter
from fsd50k_sensitive_utils import aggregate_window_scores
from validate_data import validate
PACKAGE=Path(__file__).resolve().parents[1]
SCALE=.9
FREE=np.array([0,4,5,6,8]);PROTECTED=[1,2,7]

def json_write(path,value):
    tmp=path.with_suffix('.json.part');tmp.write_text(json.dumps(value,indent=2,default=lambda x:x.tolist() if isinstance(x,np.ndarray) else x.item()),encoding='utf-8');tmp.replace(path)

def predictions(scores,thresholds):
    eligible=scores>=thresholds[None,:]*SCALE
    eligible[:,0]=False
    masked=np.where(eligible,scores,-1.)
    best=8-np.argmax(masked[:,::-1],axis=1)
    best[np.max(masked,axis=1)<0]=0
    return best

def metrics(y,p,classes):
    cm=confusion_matrix(y,p,labels=np.arange(9));support=cm.sum(1)
    precision=np.divide(np.diag(cm),cm.sum(0),out=np.zeros(9,dtype=float),where=cm.sum(0)>0)
    recall=np.divide(np.diag(cm),support,out=np.zeros(9,dtype=float),where=support>0)
    f1=np.divide(2*precision*recall,precision+recall,out=np.zeros(9,dtype=float),where=precision+recall>0)
    return {'files':len(y),'accuracy':float(np.mean(y==p)),'macro_f1':float(np.mean(f1)),
            'precision':precision.tolist(),'recall':recall.tolist(),'f1':f1.tolist(),
            'dog_as_human_count':int(cm[4,5]),'dog_as_human_rate':float(cm[4,5]/max(1,support[4])),
            'confusion_matrix':cm.tolist(),
            'classification_report':classification_report(y,p,labels=np.arange(9),target_names=classes,output_dict=True,zero_division=0)}

def main():
    parser=argparse.ArgumentParser(description="Latest constrained MLP retraining and validation-only threshold calibration")
    parser.add_argument('--features',type=Path,default=PACKAGE/'data/features.joblib')
    parser.add_argument('--initial-model',type=Path,default=PACKAGE/'models/initial_model.joblib')
    parser.add_argument('--output',type=Path,default=None)
    parser.add_argument('--mode',choices=['full','thresholds'],default='full')
    parser.add_argument('--check-only',action='store_true')
    args=parser.parse_args()
    if not args.features.is_file():parser.error('Feature data missing; run build_dataset.py first.')
    artifact=joblib.load(args.initial_model)
    records=joblib.load(args.features)['records']
    checked=validate(records,artifact)
    print('DATA CHECK',json.dumps(checked),flush=True)
    if args.check_only:return
    output=args.output or PACKAGE/'runs'/time.strftime('run_%Y%m%d_%H%M%S')
    if output.exists() and any(output.iterdir()):parser.error('Output directory is not empty. Choose a new --output.')
    output.mkdir(parents=True,exist_ok=True)
    reports=output/'reports';reports.mkdir()
    pipe=artifact['pipeline'];clf=pipe['classifier'];classes=list(map(str,clf.classes_))
    baseline_threshold=np.array([artifact['thresholds'][s] for s in classes])
    class_id={s:i for i,s in enumerate(classes)}
    def hidden(x):
        x=pipe['scaler'].transform(x)
        for w,b in zip(clf.coefs_[:-1],clf.intercepts_[:-1]):x=np.maximum(x@w+b,0)
        return x
    def group(split,role):
        selected=[r for r in records if r['split']==split and (r['role']=='ordinary_impact')==role and r['role']!='device_augmentation']
        sizes=[len(r['features']) for r in selected]
        allx=np.vstack([r['features'] for r in selected])
        return selected,sizes,hidden(allx)
    groups={key:group(*key) for key in [('val',False),('val',True),('eval',False),('eval',True)]}
    w0=clf.coefs_[-1].astype(np.float64);b0=clf.intercepts_[-1].astype(np.float64)
    def scores_for(w,b,key):
        selected,sizes,h=groups[key]
        prob=softmax(h@w+b,axis=1)
        offsets=np.r_[0,np.cumsum(sizes)]
        scores=np.vstack([aggregate_window_scores(prob[offsets[i]:offsets[i+1]],classes,3) for i in range(len(sizes))])
        y=np.array([class_id[r['label']] for r in selected])
        return y,scores
    yval,base_scores=scores_for(w0,b0,('val',False))
    _,base_hard=scores_for(w0,b0,('val',True))
    bm=metrics(yval,predictions(base_scores,baseline_threshold),classes)
    bh=predictions(base_hard,baseline_threshold)
    base_hard_rate=float(np.isin(bh,[6,8]).mean())
    print('BASELINE VALIDATION',json.dumps({'dog_f1':bm['f1'][4],'dog_as_human':bm['dog_as_human_count'],
          'ordinary_impact_alarm_rate':base_hard_rate,'protected_recalls':[bm['recall'][i] for i in PROTECTED]}),flush=True)
    def objective(scores,hard,thresholds,details=False):
        pred=predictions(scores,thresholds);hp=predictions(hard,thresholds)
        m=metrics(yval,pred,classes)
        hrate=float(np.isin(hp,[6,8]).mean());anyrate=float((hp!=0).mean())
        value=m['macro_f1']+.6*m['f1'][4]+.20*m['recall'][4]-.5*m['dog_as_human_rate']-.70*hrate-.15*anyrate
        penalty=0.
        for i in PROTECTED:
            penalty+=30*max(0,bm['recall'][i]-.015-m['recall'][i])
            penalty+=12*max(0,bm['f1'][i]-.03-m['f1'][i])
        penalty+=15*max(0,bm['precision'][4]-.06-m['precision'][4])
        penalty+=10*max(0,bm['f1'][4]-.015-m['f1'][4])
        penalty+=8*max(0,m['dog_as_human_rate']-bm['dog_as_human_rate'])
        penalty+=8*max(0,bm['recall'][5]-.10-m['recall'][5])
        penalty+=8*max(0,bm['recall'][6]-.20-m['recall'][6])
        penalty+=8*max(0,bm['recall'][8]-.15-m['recall'][8])
        penalty+=10*max(0,bm['macro_f1']-.035-m['macro_f1'])
        if details:return {'objective':float(value-penalty),'metrics':m,'hard_negative_false_alarm_rate':hrate,
                           'hard_negative_any_alert_rate':anyrate,'penalty':float(penalty)}
        return value-penalty
    def calibrate(scores,hard):
        t=baseline_threshold.copy()
        grids={4:np.unique(np.r_[t[4],np.linspace(max(.30,t[4]*.80),min(.75,t[4]*1.12),17)]),
               5:np.unique(np.r_[t[5],np.linspace(t[5],min(.94,t[5]+.20),15)]),
               6:np.unique(np.r_[t[6],np.linspace(t[6],.98,24)]),
               8:np.unique(np.r_[t[8],np.linspace(t[8],.98,20)])}
        best=objective(scores,hard,t)
        for _ in range(4):
            changed=False
            for i in [6,8,4,5]:
                chosen=t[i]
                for v in grids[i]:
                    trial=t.copy();trial[i]=v;score=objective(scores,hard,trial)
                    if score>best+1e-10:best=score;chosen=v
                if chosen!=t[i]:changed=True;t[i]=chosen
            if not changed:break
        return t,objective(scores,hard,t,True)
    baseline_t,baseline_policy=calibrate(base_scores,base_hard)
    candidates=[{'name':'threshold_only','w':w0.copy(),'b':b0.copy(),'thresholds':baseline_t,'validation':baseline_policy}]
    if args.mode=='full':
        train=[r for r in records if r['split']=='train']
        x=np.vstack([r['features'] for r in train]);y=np.concatenate([np.full(len(r['features']),class_id[r['label']],dtype=int) for r in train])
        h=hidden(x).astype(np.float64);del x
        roles=np.concatenate([np.full(len(r['features']),r['role']) for r in train])
        sample_weight=compute_sample_weight('balanced',y)
        multipliers=np.array([1.15,1.8,1.8,1.,1.8,1.15,.8,1.8,.8])
        sample_weight*=multipliers[y]
        sample_weight[roles=='ordinary_impact']*=3.
        pos=0
        for r in train:
            n=len(r['features']);labels=set(r['original_labels'].split(','))
            if r['label']=='impact_emergency' and 'Boom' in labels and not labels&{'Explosion','Gunshot_and_gunfire','Shatter','Fireworks'}:sample_weight[pos:pos+n]*=.35
            pos+=n
        sample_weight/=sample_weight.sum()
        teacher=softmax(h@w0+b0,axis=1)
        distill=np.where((roles=='base')&np.isin(y,PROTECTED),1.,0.)
        distill+=np.where((roles=='base')&(teacher.argmax(1)==y)&~np.isin(y,[4,5,6,8]),.05,0.)
        distill/=max(1.,distill.sum())
        start=np.r_[w0[:,FREE].ravel(),b0[FREE]]
        def unpack(theta):
            w=w0.copy();b=b0.copy();w[:,FREE]=theta[:64*5].reshape(64,5);b[FREE]=theta[64*5:]
            return w,b
        for name,lam,bound in [('gentle',3.,.025),('focused',1.,.05)]:
            json_write(output/'training_status.json',{'phase':'training','candidate':name,'last_layer_only':True})
            count=[0]
            def loss(theta):
                w,b=unpack(theta);logits=h@w+b;lp=logits-logsumexp(logits,axis=1)[:,None];p=np.exp(lp)
                cost=-float(np.sum(sample_weight*lp[np.arange(len(y)),y]))
                grad=p.copy();grad[np.arange(len(y)),y]-=1;grad*=sample_weight[:,None]
                cost+=lam*float(-np.sum(distill[:,None]*teacher*lp))
                grad+=lam*distill[:,None]*(p-teacher)
                delta=theta-start;cost+=.10*float(np.mean(delta**2))
                result=np.r_[(h.T@grad)[:,FREE].ravel(),grad.sum(0)[FREE]]+.2*delta/len(delta)
                count[0]+=1
                if count[0]%25==0:print(name,'step',count[0],'objective',cost,flush=True)
                return cost,result
            limits=[(float(v-bound),float(v+bound)) for v in start[:320]]+[(float(v-.15),float(v+.15)) for v in start[320:]]
            with threadpool_limits(limits=2):
                fit=minimize(loss,start,method='L-BFGS-B',jac=True,bounds=limits,options={'maxiter':100,'ftol':1e-8,'gtol':1e-6,'maxls':25})
            w,b=unpack(fit.x)
            _,vs=scores_for(w,b,('val',False));_,hs=scores_for(w,b,('val',True))
            t,result=calibrate(vs,hs)
            candidates.append({'name':name,'w':w,'b':b,'thresholds':t,'validation':result,
                               'optimization':{'success':bool(fit.success),'message':str(fit.message),'iterations':int(fit.nit)}})
            print('VALIDATION',name,json.dumps(result),flush=True)
        from full_network import checkpoints
        json_write(output/'training_status.json',{'phase':'training','candidate':'teacher_constrained_full_network'})
        def full_scores(weights,biases,key):
            selected,sizes,_=groups[key]
            values=pipe['scaler'].transform(np.vstack([r['features'] for r in selected]))
            for w,b in zip(weights[:-1],biases[:-1]):values=np.maximum(values@w+b,0)
            probabilities=softmax(values@weights[-1]+biases[-1],axis=1)
            offsets=np.r_[0,np.cumsum(sizes)]
            return np.vstack([aggregate_window_scores(probabilities[offsets[i]:offsets[i+1]],classes,3) for i in range(len(sizes))])
        for epoch,weights,biases in checkpoints(pipe,train,y,sample_weight,teacher,distill):
            vs=full_scores(weights,biases,('val',False));hs=full_scores(weights,biases,('val',True))
            thresholds,result=calibrate(vs,hs)
            candidates.append({'name':'full_epoch_'+str(epoch),'w':weights[-1],'b':biases[-1],
                               'all_weights':weights,'all_biases':biases,'thresholds':thresholds,'validation':result})
            print('VALIDATION FULL',epoch,'objective',result['objective'],'penalty',result['penalty'],
                  'dog F1',result['metrics']['f1'][4],flush=True)
    # Neither the existing eval set nor the new 180-clip ordinary-impact test
    # participates in optimization, threshold calibration, or candidate choice.
    feasible=[c for c in candidates if c['validation']['penalty']<1e-10]
    chosen=max(feasible or candidates,key=lambda c:c['validation']['objective'])
    print('SELECTED',chosen['name'],flush=True)
    tuned=copy.deepcopy(artifact)
    tuned['pipeline']['classifier'].coefs_[-1]=chosen['w'].astype(np.float32)
    tuned['pipeline']['classifier'].intercepts_[-1]=chosen['b'].astype(np.float32)
    if 'all_weights' in chosen:
        tuned['pipeline']['classifier'].coefs_=[a.astype(np.float32) for a in chosen['all_weights']]
        tuned['pipeline']['classifier'].intercepts_=[a.astype(np.float32) for a in chosen['all_biases']]
    tuned['thresholds']={s:float(chosen['thresholds'][i]) for i,s in enumerate(classes)}
    tuned['created_utc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
    # Protected output logits are exact, although softmax normalization can vary.
    if 'all_weights' not in chosen:
        assert np.array_equal(tuned['pipeline']['classifier'].coefs_[-1][:,PROTECTED],clf.coefs_[-1][:,PROTECTED])
        assert np.array_equal(tuned['pipeline']['classifier'].intercepts_[-1][PROTECTED],clf.intercepts_[-1][PROTECTED])
    for i in PROTECTED:assert tuned['thresholds'][classes[i]]==artifact['thresholds'][classes[i]]
    modeldir=output/'models';modeldir.mkdir(exist_ok=True)
    target=modeldir/'fsd50k_danger_mlp.joblib';joblib.dump(tuned,target,compress=3)
    exporter.export_npz(tuned['pipeline'],exporter.FeatureConfig(),tuned['thresholds'],SimpleNamespace(default_threshold=.45,top_windows=3,evaluation_hop=.5),target.with_suffix('.npz'))
    summary={'selection':'validation only; protect traffic recalls/F1; reduce ordinary-impact false alarms and dog-human confusion',
             'selected_candidate':chosen['name'],'threshold_scale_for_metrics':SCALE,'classes':classes,
             'baseline_thresholds':dict(zip(classes,baseline_threshold.tolist())),
             'tuned_thresholds':tuned['thresholds'],
             'candidate_validation':[{k:v for k,v in c.items() if k not in ['w','b','all_weights','all_biases']} for c in candidates],
             'baseline_validation':bm,'baseline_hard_negative_validation_alarm_rate':base_hard_rate,
             'output_columns_protected':PROTECTED if 'all_weights' not in chosen else [],
             'hidden_layers_changed':'all_weights' in chosen,'board_tested':False,
             'notes':['File-level top-three-window aggregation, with deployed 0.90 threshold scale.',
                      'This is not a live four-channel board false-alarm benchmark.',
                      'Public augmentation is not a substitute for actual INMP441 recordings.',
                      'Prior eval has been reported in V1; fresh ordinary-impact eval IDs are disjoint from prior data.']}
    for label,w,b,thresholds in [('baseline',w0,b0,baseline_threshold),('tuned',chosen['w'],chosen['b'],chosen['thresholds'])]:
        if label=='tuned' and 'all_weights' in chosen:
            y=np.array([class_id[r['label']] for r in groups[('eval',False)][0]])
            s=full_scores(chosen['all_weights'],chosen['all_biases'],('eval',False))
            hs=full_scores(chosen['all_weights'],chosen['all_biases'],('eval',True))
        else:
            y,s=scores_for(w,b,('eval',False));_,hs=scores_for(w,b,('eval',True))
        m=metrics(y,predictions(s,thresholds),classes);hp=predictions(hs,thresholds)
        summary[label+'_eval']=m
        summary[label+'_hard_negative_eval']={'files':len(hp),'impact_or_siren_count':int(np.isin(hp,[6,8]).sum()),
                'impact_count':int((hp==6).sum()),'siren_count':int((hp==8).sum()),
                'impact_or_siren_rate':float(np.isin(hp,[6,8]).mean()),'any_alert_count':int((hp!=0).sum())}
    json_write(reports/'focused_report.json',summary)
    # Compatibility schema for the existing numerical/ARM packaging checks.
    compatibility={'selected_candidate':chosen['name'],'original_model_eval':summary['baseline_eval'],
                   'retrained_model_eval':summary['tuned_eval'],'board_tested':False,
                   'threshold_scale_for_metrics':SCALE,'focused_report':'focused_report.json'}
    json_write(reports/'comparison.json',compatibility)
    json_write(output/'run_config.json',{
        'features':str(args.features.resolve()),'initial_model':str(args.initial_model.resolve()),
        'mode':args.mode,'selected_candidate':chosen['name'],'data_summary':checked,
        'notes':'Core training/calibration retained; packaging-only legacy paths removed.'})
    print('MODEL OUTPUT',str(target.resolve()),flush=True)
    print(json.dumps({k:summary[k] for k in ['selected_candidate','baseline_hard_negative_eval','tuned_hard_negative_eval']},indent=2),flush=True)

if __name__=='__main__':main()
