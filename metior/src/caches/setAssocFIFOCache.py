import random
import numpy as np

cache_debug = False

INVALID_TAG = -1

class setAssocFIFOCache:
    def __init__(self, numLines, associativity, lineSize):
        self.numLines = numLines
        self.associativity = associativity
        self.lineSize = lineSize 

        self.tagStore = np.ones((int(numLines/associativity), associativity), dtype=np.int32) * INVALID_TAG
        self.ageStore = np.zeros((int(numLines/associativity), associativity), dtype=np.int32) 

    def clearCache(self, debug=False):
        self.tagStore = np.ones((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) * INVALID_TAG
        self.ageStore = np.zeros((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) 

    def getTag(self, addr):
        return int(addr / (self.lineSize * (self.numLines / self.associativity)))

    def getSet(self, addr):
        return int((addr / self.lineSize) % (self.numLines / self.associativity))

    def cacheAccess(self, addr, debug=False):
        setIndex = self.getSet(addr)
        tag = self.getTag(addr)
        for way_id in range(self.associativity):
            if self.tagStore[setIndex][way_id] == tag:
                return True
        self.updateFIFO(setIndex)
        return False

    def cacheRepl(self, addr, debug):
        assert(self.cacheAccess(addr) is False)
        setIndex = self.getSet(addr)
        # Get list of invalid tags and randomly select one if available
        invalids = [way_id for way_id in range(self.associativity) if self.tagStore[setIndex][way_id] == INVALID_TAG] 
        if invalids:
            way_id = random.choice(invalids)
            self.insert(addr, setIndex, way_id)
            return               
        # Find oldest line (the one with the highest age) in the set
        oldest_age = 0
        oldest_way_id = 0
        for way_id in range(self.associativity):
            if self.ageStore[setIndex, way_id] > oldest_age:
                oldest_age = self.ageStore[setIndex, way_id]
                oldest_way_id = way_id
        self.insert(addr, setIndex, oldest_way_id)
        return

    def insert(self, addr, setIndex, way_id):
        self.updateFIFO(setIndex)
        self.ageStore[setIndex][way_id] = 0  # Reset
        self.tagStore[setIndex, way_id] = self.getTag(addr)
        return
    
    def updateFIFO(self, setIndex):
        # Increment the age of all lines in the set
        for i in range(self.associativity):
            if self.tagStore[setIndex][i] != INVALID_TAG:
                self.ageStore[setIndex, i] += 1