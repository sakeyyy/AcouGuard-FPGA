"""Synthetic protocol regression; no board or microphone accuracy claim."""
from pathlib import Path
import sys,json
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src/web'))
from protocol import Parser,encode
from board_text import BoardTextReader
from dsp import Processor

events=[];p=Parser(BoardTextReader(events.append).feed)
x=np.arange(-128,128,dtype=np.int16)
data=b'Sound: dog_bark\r\n'+encode(x,4000,1,7)+b'Sound: car_horn\r\nCAPTURE FAILED -3\r\n'
packets=[]
for n in range(0,len(data),7):packets.extend(p.feed(data[n:n+7]))
assert len(packets)==1 and np.array_equal(packets[0]['samples'][:,0],x)
assert [e['label'] for e in events if e['type']=='recognition']==['dog_bark','car_horn']
assert any(e['type']=='board_error' for e in events)
bad=bytearray(encode(x,4000,1,8));bad[-1]^=1
p=Parser();v=p.feed(bad+encode(x,4000,1,9))
assert len(v)==1 and v[0]['sequence']==9 and p.crc_errors>=1
four=np.tile(x[:,None],(1,4));v=Parser().feed(encode(four,4000,1,10))
assert np.array_equal(v[0]['samples'],four)
result=Processor().process(packets[0],(80,1000,0))
assert result['type']=='audio'
print(json.dumps({'synthetic_only':True,'fragmentation':True,'classification_demultiplexing':True,'crc_recovery':True,'four_channel_parser':True,'dsp_processing':True}))
