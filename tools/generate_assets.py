"""Generate project-original tones and a tiny geometric tray icon, no samples/fonts/downloads.
The generated WAV and PNG are dedicated to CC0-1.0; see ASSET_LICENSE.md.
"""
from pathlib import Path
import math,wave,array,zlib,struct
root=Path(__file__).resolve().parents[1]
assets=root/'desktop/app/assets';assets.mkdir(exist_ok=True)
rate=22050;duration=48;audio=array.array('h')
# Project-created slow pentatonic pattern; no recorded music or external score.
notes=[60,67,62,69,64,67,62,72, 64,69,60,67,62,74,69,64]
for i in range(rate*duration):
 t=i/rate;step=int(t/1.5);phase=t-step*1.5
 def hz(m):return 440*2**((m-69)/12)
 f=hz(notes[step%len(notes)]);env=min(1,phase/.06)*math.exp(-phase*2.4)
 tone=(math.sin(2*math.pi*f*phase)+.18*math.sin(2*math.pi*f*2*phase))*env
 bass=.2*math.sin(2*math.pi*hz([48,55,50,57][step//4%4])*t)
 fade=min(1,t/2,(duration-t)/2)
 audio.append(int(6000*(tone+bass)*max(0,fade)))
with wave.open(str(assets/'study-garden.wav'),'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(rate);f.writeframes(audio.tobytes())
def chunk(kind,b):return struct.pack('>I',len(b))+kind+b+struct.pack('>I',zlib.crc32(kind+b)&0xffffffff)
rows=[]
for y in range(32):
 row=bytearray([0])
 for x in range(32):
  inside=((x-16)/12)**2+((y-17)/13)**2<=1
  eye=((x-12)**2+(y-16)**2<2)or((x-20)**2+(y-16)**2<2)
  row.extend((82,100,106,255) if eye else (168,205,187,255) if inside else (0,0,0,0))
 rows.append(row)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',32,32,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join(rows)))+chunk(b'IEND',b'')
(assets/'tray.png').write_bytes(png)
print('Generated original 48-second study-garden.wav and geometric tray.png')
