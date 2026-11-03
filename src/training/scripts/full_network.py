"""Small Adam updates with teacher distillation and dog/human pair loss."""
import numpy as np
from scipy.special import softmax
from threadpoolctl import threadpool_limits

def checkpoints(pipe,records,y,sample_weight,teacher,distill):
    x=np.vstack([r['features'] for r in records])
    x=pipe['scaler'].transform(x).astype(np.float32)
    classifier=pipe['classifier']
    origin=[a.copy() for a in classifier.coefs_+classifier.intercepts_]
    parameters=[a.copy() for a in origin]
    first=[np.zeros_like(a) for a in parameters];second=[np.zeros_like(a) for a in parameters]
    weight=(sample_weight*len(y)).astype(np.float32)
    distill=(distill*len(y)).astype(np.float32)
    teacher=teacher.astype(np.float32)
    rng=np.random.default_rng(78123);step=0
    with threadpool_limits(limits=2):
        for epoch in range(1,21):
            losses=[]
            for start in range(0,len(y),256):
                # A fixed shuffled order for each epoch, with all augmentations
                # remaining exclusively in the source file's training split.
                if start==0:order=rng.permutation(len(y))
                ix=order[start:start+256];m=len(ix);xb=x[ix];yb=y[ix]
                w0,w1,w2,b0,b1,b2=parameters
                a1=np.maximum(xb@w0+b0,0);a2=np.maximum(a1@w1+b1,0)
                logits=a2@w2+b2;p=softmax(logits,axis=1)
                delta=p.copy();delta[np.arange(m),yb]-=1
                delta*=weight[ix,None]
                delta+=1.5*distill[ix,None]*(p-teacher[ix])
                pair=np.isin(yb,[4,5])
                if pair.any():
                    pp=softmax(logits[pair][:,[4,5]],axis=1)
                    pp[np.arange(pair.sum()),(yb[pair]==5).astype(int)]-=1
                    delta[np.ix_(pair,[4,5])]+=.25*pp
                delta/=m
                g2=a2.T@delta;gb2=delta.sum(0)
                d2=(delta@w2.T)*(a2>0);g1=a1.T@d2;gb1=d2.sum(0)
                d1=(d2@w1.T)*(a1>0);g0=xb.T@d1;gb0=d1.sum(0)
                gradients=[g0,g1,g2,gb0,gb1,gb2]
                gradients=[(g+.02*(v-old)).astype(np.float32) for g,v,old in zip(gradients,parameters,origin)]
                norm=np.sqrt(sum(float(np.sum(g.astype(np.float64)**2)) for g in gradients))
                factor=min(1.,5./max(norm,1e-8));step+=1
                for i,g in enumerate(gradients):
                    g*=factor;first[i]=.9*first[i]+.1*g;second[i]=.999*second[i]+.001*g*g
                    parameters[i]-=2e-5*(first[i]/(1-.9**step))/(np.sqrt(second[i]/(1-.999**step))+1e-8)
                losses.append(float(-np.mean(np.log(np.maximum(p[np.arange(m),yb],1e-10)))))
            print('full_network epoch',epoch,'CE',float(np.mean(losses)),flush=True)
            if epoch in [4,8,12,16,20]:
                yield epoch,[a.copy() for a in parameters[:3]],[a.copy() for a in parameters[3:]]
