import numpy as np

cache_debug = False
INVALID_TAG = -1 

def parent_index(i: int) -> int:
    return (i - 1) // 2

def left_index(i: int) -> int:
    return 2 * i + 1

def right_index(i: int) -> int:
    return 2 * i + 2

def is_right_subtree(i: int) -> bool:
    return (i % 2) == 0


class TreePLRU:
    def __init__(self, num_leaves):
        self.num_leaves = num_leaves
        self.tree = np.zeros(num_leaves - 1, dtype=bool)  # False = left, True = right

    def touch(self, leaf_index):
        idx = leaf_index
        while idx != 0:
            right = is_right_subtree(idx)
            idx = parent_index(idx)
            self.tree[idx] = not right  # point away from MRU

    def get_victim(self):
        idx = 0
        while idx < len(self.tree):
            if self.tree[idx]:
                idx = right_index(idx)
            else:
                idx = left_index(idx)
        return idx - (self.num_leaves - 1)

class setAssocTreePLRUCache:
    def __init__(self, numLines, associativity, lineSize):
        self.numLines = numLines
        self.associativity = associativity
        self.lineSize = lineSize 

        self.num_sets = int(numLines / associativity)
        self.tagStore = np.ones((self.num_sets, associativity), dtype=np.int32) * INVALID_TAG
        self.plruTrees = [TreePLRU(associativity) for _ in range(self.num_sets)]

    def clearCache(self, debug=False):
        self.tagStore = np.ones((self.num_sets, self.associativity), dtype=np.int32) * INVALID_TAG
        self.plruTrees = [TreePLRU(self.associativity) for _ in range(self.num_sets)]

    def getTag(self, addr):
        return int(addr / (self.lineSize * (self.numLines / self.associativity)))

    def getSet(self, addr):
        return int((addr / self.lineSize) % (self.numLines / self.associativity))

    def cacheAccess(self, addr, debug=False):
        tag = self.getTag(addr)
        setIndex = self.getSet(addr)
        for way_id in range(self.associativity):               
            if tag == self.tagStore[setIndex, way_id]:
                self.plruTrees[setIndex].touch(way_id)
                return True
        return False

    def cacheRepl(self, addr, debug=False):
        assert(self.cacheAccess(addr) is False)       
        setIndex = self.getSet(addr)
        tree = self.plruTrees[setIndex]
        for way_id in range(self.associativity):    
            # Prioritize invalid tags           
            if self.tagStore[setIndex, way_id] == INVALID_TAG:
                self.tagStore[setIndex, way_id] = self.getTag(addr)
                tree.touch(way_id)
                return
        victim_way = tree.get_victim()
        self.tagStore[setIndex, victim_way] = self.getTag(addr)
        tree.touch(victim_way)
