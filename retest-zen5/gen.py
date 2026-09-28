import random, sys, struct
# usage: gen.py w h frames bpc fmt(420|444) seed out
w,h,n,bpc=map(int,sys.argv[1:5]); fmt=sys.argv[5]; seed=int(sys.argv[6]); out=sys.argv[7]
noise=int(sys.argv[8]) if len(sys.argv)>8 else 0
random.seed(seed)
cw,ch=(w//2,h//2) if fmt=='420' else (w,h)
mx=(1<<bpc)-1
base=random.Random(1234)
with open(out,'wb') as f:
    for fr in range(n):
        for (pw,ph) in [(w,h),(cw,ch),(cw,ch)]:
            vals=[]
            for y in range(ph):
                for x in range(pw):
                    v=((x*7+y*13+fr*5)*(mx//255 if bpc>8 else 1))%(mx+1)
                    v=(v+base.randint(0,mx//8))%(mx+1) if False else v
                    if noise: v=min(mx,max(0,v+random.randint(-noise,noise)))
                    vals.append(v)
            if bpc>8: f.write(struct.pack('<%dH'%len(vals),*vals))
            else: f.write(bytes(vals))
