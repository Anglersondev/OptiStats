#!/usr/bin/env python3
"""Measure interval CPU time and RSS. No dependencies; normal user privileges."""
import argparse,csv,ctypes,json,os,statistics,struct,subprocess,sys,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('seconds',type=int,nargs='?',default=300)
p.add_argument('process',nargs='?',default='OptiStats')
p.add_argument('--pid',type=int)
p.add_argument('--output',type=Path)
a=p.parse_args()
if a.seconds<=0:p.error('seconds must be positive')
if a.pid:pid=a.pid
else:
    pids=subprocess.run(['pgrep','-x',a.process],text=True,capture_output=True).stdout.split()
    if len(pids)!=1:sys.exit('Choose exactly one running process, or pass --pid.')
    pid=int(pids[0])
lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
lib.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
lib.proc_pid_rusage.restype=ctypes.c_int

def sample():
    buffer=ctypes.create_string_buffer(1024)
    if lib.proc_pid_rusage(pid,4,buffer)!=0:raise RuntimeError('proc_pid_rusage failed')
    # rusage_info_v0 is the stable prefix of v4; CPU counters use Mach absolute time.
    user,system=struct.unpack_from('QQ',buffer,16)
    rss,footprint=struct.unpack_from('QQ',buffer,64)
    start=struct.unpack_from('Q',buffer,80)[0]
    return time.monotonic(),user+system,rss,footprint,start
class Timebase(ctypes.Structure):_fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
tb=Timebase();ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(tb))
scale=tb.numer/tb.denom/1e9
rows=[];first=prev=sample()
writer=csv.writer(sys.stdout);writer.writerow(['elapsed_s','cpu_percent_one_core','rss_mib','footprint_mib'])
end=first[0]+a.seconds
while time.monotonic()<end:
    time.sleep(min(5,max(0,end-time.monotonic())))
    now=sample()
    if now[4]!=first[4]:raise RuntimeError('PID changed identity during measurement')
    elapsed=now[0]-prev[0];cpu=max(0,now[1]-prev[1])*scale/elapsed*100
    row={'elapsed_s':round(now[0]-first[0],3),'cpu_percent_one_core':round(cpu,4),'rss_mib':round(now[2]/2**20,3),'footprint_mib':round(now[3]/2**20,3)}
    rows.append(row);writer.writerow(row.values());sys.stdout.flush();prev=now
report={'pid':pid,'duration_s':rows[-1]['elapsed_s'],'cpu_percent_one_core_mean':round((prev[1]-first[1])*scale/(prev[0]-first[0])*100,4),
        'rss_mib_mean':round(statistics.mean(r['rss_mib'] for r in rows),3),'rss_mib_peak':max(r['rss_mib'] for r in rows),
        'footprint_mib_mean':round(statistics.mean(r['footprint_mib'] for r in rows),3),'footprint_mib_peak':max(r['footprint_mib'] for r in rows),
        'samples':rows,'macos':subprocess.check_output(['sw_vers','-productVersion'],text=True).strip()}
print(json.dumps({k:v for k,v in report.items() if k!='samples'},ensure_ascii=False),file=sys.stderr)
if a.output:a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n')
