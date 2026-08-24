class Cache():
    def __init__(self, assoc, size):
        self.assoc = assoc
        self.size = size 
        pass
    def p0(self):
        '''
        Probability of selected memory line brought
        into the cache given the accessed memory line
        '''
        return 1.0
    def p1(self):
        '''Map from memory address to cache set (index mapping)'''
        return 1.0
    
    def p11(self):
        '''Map from memory address to cache set (index mapping)'''
        return 1.0
    
    def p2(self):
        '''Map from cache set to cache line (replacement policy)'''
        return 1.0
    def p3(self):
        '''
        Map from cache line to the memory line 
        evicted out of the cache (line locking policy)
        '''
        return 1.0
    def p4(self):
        '''
        Map from evicted memory line and accessed memory line 
        to whether the access is a hit or miss (hit/miss policy)
        '''
        return 1.0
    def p5(self):
        '''Map from hit/miss to access time (noise in timing)'''
        return 1.0
    
class SetAssoc(Cache):
    def __init__(self, assoc, size):
        super().__init__(assoc, size)
        
    def p2(self):
        return 1/self.assoc

class SkewedAssoc(Cache):
    def __init__(self, assoc, size, skews):
        super().__init__(assoc, size)
        self.skews = skews
        self.nsets = (size/64)/assoc
    def p1(self):
        return 1
    def p2(self):
        return 1/self.assoc
    
class ScatterCache(SkewedAssoc):
    def __init__(self, assoc, size, skews, domains):
        super().__init__(assoc, size, skews)
        self.domains = domains
        self.nsets = (size/64)/assoc
    def p1(self):
        return 1 - (1 - 1/self.nsets)**self.skews
    
class SassCache(SkewedAssoc):
    def __init__(self, assoc, size, skews, domains, t):
        super().__init__(assoc, size, skews)
        self.domains = domains
        self.nsets = (size/64)/assoc
        import math
        self.c = 1-math.exp(-2**t)
    def p1(self):
        return 1
    def p2(self):
        return self.c**self.assoc
    
class WayPartitioned(Cache):
    def __init__(self, assoc, size, parts):
        super().__init__(assoc, size)
        self.parts = parts
    def p2(self):
        return 1/self.assoc
    def p3(self):
        return 0
    
caches = (
    "set-assoc",
    "skewed",
    "scattercache",
    "way-part",
    "sass"
)

def get_cache(args):
    if args.type == "set-assoc":
        return SetAssoc(assoc=args.assoc, size=args.size)
    elif args.type == "skewed":
        return SkewedAssoc(assoc=args.assoc, size=args.size, skews=args.parts)
    elif args.type == "scattercache":
        return ScatterCache(
            assoc=args.assoc, size=args.size, skews=args.parts, domains=args.domains)
    elif args.type == "way-part":
        return WayPartitioned(assoc=args.assoc, size=args.size, parts=args.parts)
    elif args.type == "sass":
        return SassCache(
            assoc=args.assoc, size=args.size, skews=args.parts, domains=args.domains, t=-1
        )