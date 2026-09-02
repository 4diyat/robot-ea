import io,glob,re
def strip(s):
    out=[];i=0;n=len(s);st=0
    while i<n:
        c=s[i]; nx=s[i+1] if i+1<n else ''
        if st==0:
            if c=='"':st=1;out.append(' ')
            elif c=='/' and nx=='/':st=2
            elif c=='/' and nx=='*':st=3;i+=1
            else:out.append(c)
        elif st==1:
            if c=='\\':out.append(' ');i+=1
            elif c=='"':st=0
            out.append(' ')
        elif st==2:
            out.append(' ' if c!='\n' else c)
            if c=='\n':st=0
        else:
            out.append(' ' if c!='\n' else c)
            if c=='*' and nx=='/':st=0;i+=1
        i+=1
    return ''.join(out)
pat=re.compile(r'^(void|bool|int|double|long|datetime|string|color|uchar|uint)\s+[\w:]+\s*\(')
bad=0
for f in ['ORB_SMC_Hunter_EA.mq5']+sorted(glob.glob('Include/ORB_SMC_Hunter/*.mqh')):
    code=strip(io.open(f,encoding='utf-8').read())
    o,cl,p,q=code.count('{'),code.count('}'),code.count('('),code.count(')')
    if o!=cl or p!=q: print(f,"MISMATCH",o,cl,p,q);bad+=1
    depth=0
    for ln,line in enumerate(code.split('\n'),1):
        if line.strip().startswith(';'): print("%s:%d STRAY"%((f,ln)));bad+=1
        if pat.match(line.rstrip()) and depth>0: print("%s:%d DEPTHDEF %s"%(f,ln,line.strip()[:40]));bad+=1
        depth+=line.count('{')-line.count('}')
        if depth<0: print(f,ln,"NEG");bad+=1;break
    if depth!=0: print(f,"FINAL",depth);bad+=1
m=io.open('ORB_SMC_Hunter_EA.mq5',encoding='utf-8').read()
assert m.count("InpForceGridOff")==2 and m.count("CHART_SHOW_GRID")==1
print("CHK119:","FAIL %d"%bad if bad else "OK")
