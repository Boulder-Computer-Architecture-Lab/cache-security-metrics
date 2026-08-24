from caches import get_cache
from options import get_options

args = get_options()
cache = get_cache(args)
pas = []
print(f"Calculating PAS for {args.type}")

cache_attrs = vars(cache)
if cache_attrs:
	print("Resolved cache attributes:")
	for key, value in cache_attrs.items():
		print(f"  {key}: {value}")
print()
 
pas_et = cache.p1()*cache.p2()*cache.p3()*cache.p4()*cache.p5()
pas.append(pas_et)
print("PAS for Evict+Time (Type 1):", pas_et)


pas_pp = cache.p1()*cache.p2()*cache.p3()*cache.p4()*cache.p1()*cache.p2()*cache.p3()*cache.p4()*cache.p5()
pas.append(pas_pp)
print("PAS for Prime+Probe (Type 2):", pas_pp)

pas_cc = cache.p0()*cache.p4()*cache.p5()
pas.append(pas_cc)
print("PAS for Cache Collision (Type 3):", pas_cc)

pas_fr = cache.p0()*cache.p4()*cache.p5()
pas.append(pas_fr)
print("PAS for Flush+Reload (Type 4):", pas_fr)


print(f"Average PAS is: {sum(pas)/len(pas)}")