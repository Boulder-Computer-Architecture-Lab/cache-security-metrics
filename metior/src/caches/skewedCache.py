import numpy as np
import sys
import random
import math 

cache_debug = False
INVALID_TAG = -1
INT_MAX = sys.maxsize

class skewedCache:
    '''
    Based on the skewed-associative cache implementation from gem5.
    '''   
    def __init__(self, numLines, associativity, lineSize, numHG=16, debug=False):
        '''
        numLines: total number of lines in the cache
        associativity: number of ways
        lineSize: size of each cache line in bytes
        numHG: number of hash groups (skewing functions)
        debug: whether to print debug info during initialization
        '''
        
        self.numLines = numLines
        self.associativity = associativity
        self.lineSize = lineSize
        self.numSets = int(numLines / associativity)
        self.tagStore = np.ones((int(numLines/associativity), associativity), dtype=np.int32) * INVALID_TAG
        self.LRUStore = np.zeros((int(numLines/associativity), associativity), dtype=np.int32) 
        self.clock = 0

        self.msb_shift = math.floor(math.log2(self.numSets)) - 1
        self.setMask = self.numSets - 1
        self.NUM_SKEWING_FUNCTIONS = numHG
        self.setShift = 6

    def clearCache(self, debug=False):
        '''Reset the cache to an empty state.'''
        self.tagStore = np.ones((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) * INVALID_TAG
        self.LRUStore = np.zeros((int(self.numLines/self.associativity), self.associativity), dtype=np.int32) 
        self.clock = 0

    def getTag(self, addr):
        '''Get the tag for a given address.'''
        return int(addr / (self.lineSize * (self.numLines / self.associativity)))

    def cacheAccess(self, addr, debug):
        ''''Check if the address is in the cache and update LRU bits if it is a hit.'''
        self.clock += 1
        entries = self.getEntries(addr)
        for idx, way in entries:
            if self.tagStore[idx, way] == self.getTag(addr):
                self.touchLRU(idx, way)
                return True
        return False

    def cacheRepl(self, addr, debug):
        ''''Replace a cache line with the given address, assuming it is not already in the cache.'''
        entries = self.getEntries(addr)
        lru = INT_MAX
        victim_way = random.randint(0, self.associativity-1)
        victim_idx = random.randint(0, self.numSets-1)
        for idx, way in entries:
            if self.LRUStore[idx, way] == 0:
                self.insert(addr, idx, way)
                return 
            if self.LRUStore[idx, way] < lru:
                lru = self.LRUStore[idx, way]
                victim_way = way
                victim_idx = idx
        self.insert(addr, victim_idx, victim_way)
        return
    
    def insert(self, addr, setIndex, way_id):
        self.touchLRU(setIndex, way_id)
        self.tagStore[setIndex][way_id] = self.getTag(addr)

    def touchLRU(self, setIndex, way_id):
        self.LRUStore[setIndex, way_id] = self.clock
        return

    def getEntries(self, addr) -> list:
        '''Get the list of (set_index, way) pairs that the address maps to based on the skewing functions.'''
        entries = []
        for way in range(self.associativity):
            idx = self.extractSet(addr, way)
            entries.append([idx,way])
        return entries
    
    def extractSet(self, addr, way) -> int:
        '''Extract the set index for a given address and way number by applying the skewing function.'''
        return self.skew(addr >> self.setShift, way) & self.setMask
    
    @staticmethod
    def _bits(val: int, bit_pos: int) -> int:
        """Extract a single bit at bit_pos."""
        return (val >> bit_pos) & 1

    @staticmethod
    def _insert_bits(val: int, bit_pos: int, bit_val: int) -> int:
        """Set the bit at bit_pos to bit_val (0 or 1)."""
        if bit_val:
            return val | (1 << bit_pos)
        else:
            return val & ~(1 << bit_pos)
      
    @staticmethod
    def _get_bits(val: int, msb: int, lsb: int) -> int:
        """Extract a range of bits from lsb to msb (inclusive)."""
        mask = (1 << (msb - lsb + 1)) - 1
        return (val >> lsb) & mask

    def hash(self, addr: int) -> int:
        """Transform address by XORing LSB and MSB, then shifting."""
        # Get relevant bits
        lsb = self._bits(addr, 0)
        msb = self._bits(addr, self.msb_shift)
        xor_bit = msb ^ lsb

        # Shift off LSB and set new MSB as XOR of old LSB and MSB
        return self._insert_bits(addr >> 1, self.msb_shift, xor_bit)
    
    def dehash(self, addr: int) -> int:
        '''Reverse the hash transformation to recover original address.'''
        msb = self._bits(addr, self.msb_shift - 1)
        xor_bit = self._bits(addr, self.msb_shift)   
        lsb = msb ^ xor_bit                    
        addr_no_msb = self._get_bits(addr, self.msb_shift - 1, 0)
        return self._insert_bits(addr_no_msb << 1, 0, lsb)

    def skew(self, addr, way) -> int:
        '''Skew the address based on the way number using different hash functions.'''
        addr1 = self._get_bits(addr, self.msb_shift, 0)
        addr2 = self._get_bits(addr, 2 * (self.msb_shift + 1) - 1, self.msb_shift + 1)

        match (int(way % self.NUM_SKEWING_FUNCTIONS)):
            case 0:
                addr1 = self.hash(addr1) ^ self.hash(addr2) ^ addr2
            case 1:
                addr1 = self.hash(addr1) ^ self.hash(addr2) ^ addr1
            case 2:
                addr1 = self.hash(addr1) ^ self.dehash(addr2) ^ addr2
            case 3:
                addr1 = self.hash(addr1) ^ self.dehash(addr2) ^ addr1
            case 4:
                addr1 = self.dehash(addr1) ^ self.hash(addr2) ^ addr2
            case 5:
                addr1 = self.dehash(addr1) ^ self.hash(addr2) ^ addr1
            case 6:
                addr1 = self.dehash(addr1) ^ self.dehash(addr2) ^ addr2
            case 7:
                addr1 = self.dehash(addr1) ^ self.dehash(addr2) ^ addr1

        for i in range(int(way/self.NUM_SKEWING_FUNCTIONS)):
            addr1 = hash(addr1)

        return addr1
