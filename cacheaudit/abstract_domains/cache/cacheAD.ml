(* Copyright (c) 2013-2015, IMDEA Software Institute.             *)
(* See ../../LICENSE for authorship and licensing information     *)

open AD.DS
open NumAD.DS
open Logger
open Big_int 
open Utils

type replacement_strategy = 
  | LRU  (** least-recently used *)
  | FIFO (** first in, first out *)
  | PLRU (** tree-based pseudo LRU *)
  | MRU (** MRU *)
  | RR (** round-robin *)
  | RAND (** random *)
  | BIP (** bip *)
  | BRRIP (** bimodal re-reference interval prediction *)

type cache_param = { 
  cs: int; 
  ls: int; 
  ass: int; 
  str: replacement_strategy;
  opt_precision: bool;
  do_leakage: bool;
 } 


module type S = sig
  include AD.S
  val init : cache_param -> t
  (** initialize an empty cache
   takes arguments cache_size (in bytes), 
  line_size (in bytes) and associativity *)
  val touch : t -> int64 -> rw_t -> t
  (** reads or writes an address into cache *)

  val touch_hm : t -> int64 -> rw_t -> (t add_bottom*t add_bottom)
  (** Same as touch, but returns more precise informations about hit and misses *)
  (** @return, the first set overapproximates hit cases, the second one misses *)
  val elapse : t -> int -> t
  (** Used to keep track of time, if neccessary *)
  val count_cache_states : t -> Big_int.big_int
end

(*** Flags for modifying precision ***)

(* if following flags are true, cache updates will be done by concretizing *)
(* (for a cache set), performing update and abstracting, upon*)
(* cache hits, resp. misses*)
let do_concrete_miss = ref false
let do_concrete_hit = ref false

(* if do_concrete_miss is false, the following flag determines whether to *)
(* perform a reduction which removes impossible states with "holes" *)
let do_reduction = ref true

(* Bimodal Insertion Policy (BIP): conceptually, an allocating miss is
   inserted at MRU with probability 3% and at LRU with probability 97%.
   This abstract cache domain is non-probabilistic, so both outcomes are
   represented as separate reachable BIP states at each allocating read miss. *)
let bip_mru_probability = 0.03

(* BRRIP defaults chosen to match gem5's standard BRRIP configuration:
   2-bit RRPVs, frequency-priority on hits, and a 3% bimodal throttle.
   Unlike BIP's nondeterministic abstraction, BRRIP carries an explicit
   per-state MT19937 state so the 3% throttle is sampled once per insertion.
   This models one reproducible pseudorandom execution per abstract path. *)
let brrip_num_bits = 2
let brrip_hit_priority = false
let brrip_btp = 3
let brrip_seed = 19650218

(*If compute_leakage is true the maximum information leakage will be computed*)		       
let compute_leakage = ref false

type adversary = Disjoint | Shared

let adversary = ref Disjoint

module Make (A: AgeAD.S) = struct
  (*** Permutations corresponding to replacement strategies ***)
  
  (* Permutation to apply when touching an element of age a in PLRU *)
  (* We assume an ordering correspond to the boolean encoding of the tree from *)
  (* leaf to root. 0 is the most recent, corresponding to all 0 bits in the path *)
  let plru_permut assoc a n = if n=assoc then n else
    let rec f a n =  
      if a=0 then n 
      else 
        if a land 1 = 1 then 
  	if n land 1 = 1 then 2*(f (a/2) (n/2)) 
  	else n+1
        else (* a even*) 
  	if n land 1 = 1 then n 
  	else 2*(f (a/2) (n/2))
    in f a n
  
  (* Permutation to apply when touching an element of age a in LRU *)
  (* The touched element is assigned age 0. Elements that are younger age, *)
  (* elements that are older remain unchanged *)

  let lru_permut assoc a n = 
    if n = a then 0
    else if n < a then n+1
    else n

  let mru_permut assoc a n = 
    if n = a then 0
    else if n < a then n+1
    else n

  let rr_permut assoc a n = n

  (* Permutation corresponding to FIFO: Identity *)
      
  let fifo_permut assoc a n = n
  
  let get_permutation strategy = match strategy with
    | LRU -> lru_permut
    | FIFO -> fifo_permut
    | PLRU -> plru_permut
    | MRU -> mru_permut
    | RR -> rr_permut
    | RAND -> rr_permut
    | BIP -> lru_permut
    | BRRIP -> rr_permut
   
  (* apply function f to all elements of intset iset *)
  let intset_map f iset = 
    IntSet.fold (fun x st -> IntSet.add (f x) st) iset IntSet.empty
  
  (*** Initialization ***)
  type rr_set_state = {
    rr_next_way : int;
    rr_way_blocks : int64 IntMap.t;
  }

  module RRSetStateOrd = struct
    type t = rr_set_state

    (* Compare maps by their logical bindings rather than their tree shape. *)
    let compare a b =
      let c = Pervasives.compare a.rr_next_way b.rr_next_way in
      if c <> 0 then c
      else
        Pervasives.compare
          (IntMap.bindings a.rr_way_blocks)
          (IntMap.bindings b.rr_way_blocks)
  end

  module RRSetStateSet = Set.Make(RRSetStateOrd)

  type mt_state = {
    mt_values : int32 array;
    mt_index : int;
  }

  type rand_set_state = {
    rand_prng : mt_state;
    rand_way_blocks : int64 IntMap.t;
  }

  module RandSetStateOrd = struct
    type t = rand_set_state

    let compare a b =
      let c = Pervasives.compare a.rand_prng.mt_index b.rand_prng.mt_index in
      if c <> 0 then c
      else
        let c = Pervasives.compare a.rand_prng.mt_values b.rand_prng.mt_values in
        if c <> 0 then c
        else
          Pervasives.compare
            (IntMap.bindings a.rand_way_blocks)
            (IntMap.bindings b.rand_way_blocks)
  end

  module RandSetStateSet = Set.Make(RandSetStateOrd)


  type brrip_set_state = {
    brrip_prng : mt_state;
    brrip_way_blocks : int64 IntMap.t;
    brrip_way_rrpv : int IntMap.t;
  }

  module BRRIPSetStateOrd = struct
    type t = brrip_set_state

    let compare a b =
      let c = Pervasives.compare a.brrip_prng.mt_index b.brrip_prng.mt_index in
      if c <> 0 then c
      else
        let c = Pervasives.compare
          a.brrip_prng.mt_values b.brrip_prng.mt_values
        in
        if c <> 0 then c
        else
          let c = Pervasives.compare
            (IntMap.bindings a.brrip_way_blocks)
            (IntMap.bindings b.brrip_way_blocks)
          in
          if c <> 0 then c
          else Pervasives.compare
            (IntMap.bindings a.brrip_way_rrpv)
            (IntMap.bindings b.brrip_way_rrpv)
  end

  module BRRIPSetStateSet = Set.Make(BRRIPSetStateOrd)

  type t = {
    handled_addrs : NumSet.t; (* holds addresses handled so far *)
    cache_sets : NumSet.t IntMap.t;
    (* holds a set of addreses which fall into a cache set
        as implemented now it may also hold addresses evicted from the cache *)
    ages : A.t;
    (* for each accessed memory address holds its possible ages *)

    cache_size: int;
    line_size: int; (* same as "data block size" *)
    assoc: int;
    num_sets : int; (* computed from the previous three *)
    
    strategy : replacement_strategy;
    poss_init_ages : IntListSet.t; (* ages of the initial blocks *)

    (* for round robin *)
    rr_states : RRSetStateSet.t IntMap.t;

    (* for pseudorandom MT19937 replacement *)
    rand_states : RandSetStateSet.t IntMap.t;

    (* for BIP replacement: concrete program-block LRU stacks, preserving
       correlations between the 97% LRU-insertion and 3% MRU-insertion paths *)
    bip_states : SetState.t IntMap.t;

    (* for BRRIP replacement *)
    brrip_states : BRRIPSetStateSet.t IntMap.t;
  }
  
  let var_to_string x = Printf.sprintf "%Lx" x 
  
  let calc_set_addr num_sets addr = 
    Int64.to_int (Int64.rem addr (Int64.of_int num_sets))
    

   (* give the complement of the ages of an initial state: 
      corresponds to the set of ages of the elements loaded by the 
      program *)
       
   let complement assoc untouched  =
    let all_ages = IntSet.of_list (0 -- assoc) in
    List.fold_left (fun touched a -> 
      if a = assoc then touched 
      else IntSet.remove a touched) all_ages untouched

  (* Calculates the possible ages that the initial blocks can have throughout 
     the computation. Possible ages are lists, where l[i] = a means that
     i'th initial block has age a. 
     Examples:
        initially: [0; 1; ...; assoc - 1]; 
        all initial blocks were evicted: [assoc; ...; assoc];
        all evicted but initial block 1 which has age 3: [assoc; 3; assoc; ...; assoc]
     The complements are the sets of ages of elements in the cache.
     
     Works under the assumption that the initial blocks are disjoint 
     from the accessed locations. 
     If age != associativity, then that location is filled filled with an
     element from the initial state or is empty if initial state is empty *)
            
  let calc_poss_init_ages strategy assoc =
    let permut = get_permutation strategy in
    let rec loop ready todo = 
      if IntListSet.is_empty todo then 
	ready
    else
      let elt = IntListSet.choose todo in
      let ready = IntListSet.add elt ready in
	(* compute hit successors: simulate a hit to every *)
 	(* age that is not occupied by a block from the initial *)
 	(* state (and that could hence be touched by the program) *)
        let touched = complement assoc elt in 
        let successors = IntSet.fold (fun i succ ->
          IntListSet.add (List.map (permut assoc i) elt) succ
          ) touched IntListSet.empty in
        (* compute miss successor: increase ages of all blocks by one *)
        let miss_elts =
          match strategy with
          | MRU ->
              [List.map (fun a ->
                if a = 0 then assoc else a
              ) elt]
          | BIP ->
              (* Both outcomes are reachable: the usual LRU insertion and
                 the 3% MRU insertion. Probabilities are sampled at touch time. *)
              let lru_insert =
                List.map (fun a ->
                  if a = assoc - 1 then assoc else a
                ) elt
              in
              let mru_insert =
                List.map (fun a ->
                  if a = assoc then a else succ a
                ) elt
              in
              [lru_insert; mru_insert]
          | BRRIP ->
              (* BRRIP uses its own explicit RRPV state below; this legacy age
                 initialization is kept conservative for generic bookkeeping.
                 NOTE: this reuses the generic recency-increment approximation
                 (since get_permutation BRRIP is the identity/rr-style
                 permutation) rather than a true RRPV-aware aging of
                 background occupants. It is only used, via
                 num_poss_states/poss_init_ages, to count how many ways the
                 *untouched* ways of a BRRIP set could be filled by
                 background blocks -- see brrip_state_way_set and
                 count_brrip_set_shared/disjoint below. *)
              [List.map (fun a -> if a = assoc then a else succ a) elt]
          | _ ->
              [List.map (fun a ->
                if a = assoc then a else succ a
              ) elt]
        in
        let successors =
          List.fold_left
            (fun acc miss_elt -> IntListSet.add miss_elt acc)
            successors miss_elts
        in
	(* update worklist *)
        let todo = IntListSet.diff (IntListSet.union todo successors) ready in
        loop ready todo in
    loop IntListSet.empty (IntListSet.singleton (0 -- assoc)) 

  (* Determine the set in which an address is cached *)
  let get_set_addr env addr =
    calc_set_addr env.num_sets addr

  let rec init_rr_states states i =
    match i with
    | 0 ->
        states

    | n ->
        let initial_state = {
          rr_next_way = 0;
          rr_way_blocks = IntMap.empty;
        } in

        init_rr_states
          (IntMap.add
            (n - 1)
            (RRSetStateSet.singleton initial_state)
            states)
          (n - 1)

  let mt_n = 624
  let mt_m = 397
  let mt_matrix_a = 0x9908b0dfl
  let mt_upper_mask = 0x80000000l
  let mt_lower_mask = 0x7fffffffl

  let mt_init seed =
    let values = Array.make mt_n 0l in
    values.(0) <- seed;
    for i = 1 to mt_n - 1 do
      let prev = values.(i - 1) in
      let x = Int32.logxor prev (Int32.shift_right_logical prev 30) in
      values.(i) <-
        Int32.add
          (Int32.mul 1812433253l x)
          (Int32.of_int i)
    done;
    {
      mt_values = values;
      mt_index = mt_n;
    }

  let mt_twist state =
    let values = Array.make mt_n 0l in
    for i = 0 to mt_n - 1 do
      let y =
        Int32.logor
          (Int32.logand state.mt_values.(i) mt_upper_mask)
          (Int32.logand state.mt_values.((i + 1) mod mt_n) mt_lower_mask)
      in
      let y_shifted = Int32.shift_right_logical y 1 in
      let y_shifted =
        if Int32.logand y 1l <> 0l then
          Int32.logxor y_shifted mt_matrix_a
        else
          y_shifted
      in
      values.(i) <-
        Int32.logxor
          state.mt_values.((i + mt_m) mod mt_n)
          y_shifted
    done;
    {
      mt_values = values;
      mt_index = 0;
    }

  let mt_next state =
    let state =
      if state.mt_index >= mt_n then mt_twist state
      else state
    in
    let y = state.mt_values.(state.mt_index) in
    let y = Int32.logxor y (Int32.shift_right_logical y 11) in
    let y = Int32.logxor y (Int32.logand (Int32.shift_left y 7) 0x9d2c5680l) in
    let y = Int32.logxor y (Int32.logand (Int32.shift_left y 15) 0xefc60000l) in
    let y = Int32.logxor y (Int32.shift_right_logical y 18) in
    ({ state with mt_index = state.mt_index + 1 }, y)

  let mt_way assoc value =
    let unsigned =
      Int64.logand (Int64.of_int32 value) 0xffffffffL
    in
    Int64.to_int (Int64.rem unsigned (Int64.of_int assoc))

  let rec init_rand_states states i =
    match i with
    | 0 ->
        states

    | n ->
        let set = n - 1 in
        let initial_state = {
          rand_prng = mt_init (Int32.of_int (5489 + set));
          rand_way_blocks = IntMap.empty;
        } in

        init_rand_states
          (IntMap.add
            set
            (RandSetStateSet.singleton initial_state)
            states)
          (n - 1)

  let rec init_bip_states states i =
    match i with
    | 0 -> states
    | n ->
        init_bip_states
          (IntMap.add (n - 1) (SetState.singleton NumMap.empty) states)
          (n - 1)

  let rec init_brrip_states states i =
    match i with
    | 0 -> states
    | n ->
        let set = n - 1 in
        let initial_state = {
          brrip_prng = mt_init (Int32.of_int (brrip_seed + set));
          brrip_way_blocks = IntMap.empty;
          brrip_way_rrpv = IntMap.empty;
        } in
        init_brrip_states
          (IntMap.add set (BRRIPSetStateSet.singleton initial_state) states)
          (n - 1)

  let init cache_param =
    if cache_param.opt_precision then begin
        do_concrete_miss := true;
        do_concrete_hit := true
      end;
    compute_leakage := cache_param.do_leakage;
    let (cs,ls,ass,strategy) = (cache_param.cs, cache_param.ls,
      cache_param.ass,cache_param.str) in
    let ns = cs / ls / ass in (* number of sets *)
    let rec init_csets csets i = match i with
    | 0 -> csets
    | n -> init_csets (IntMap.add (n - 1) NumSet.empty csets) (n - 1) in
    let poss_init_ages = calc_poss_init_ages strategy ass in
    { cache_sets = init_csets IntMap.empty ns;
      ages = A.init ass (calc_set_addr ns) var_to_string;
      handled_addrs = NumSet.empty;
      cache_size = cs;
      line_size = ls;
      assoc = ass;
      num_sets = ns;
      strategy = strategy;
      poss_init_ages = poss_init_ages;
      rr_states = init_rr_states IntMap.empty ns;
      rand_states = init_rand_states IntMap.empty ns;
      bip_states = init_bip_states IntMap.empty ns;
      brrip_states = init_brrip_states IntMap.empty ns;
    }
  
  (* Gives the block address *)
  let get_block_addr env addr = Int64.div addr (Int64.of_int env.line_size)
  
    
  (*** Functions for concretization, filtering and abstraction ***)

  (* return a set of the ages of a concrete set state, *)
  (* and a boolean value indicating whether there were duplicate ages (not assoc) *)
  let get_ages env state = NumMap.fold (fun _ age (age_set,d) -> 
    if age = env.assoc then (* assoc is always a possible age, don't consider it *)
      (age_set,d)
    else
      let d = d || (IntSet.mem age age_set) in (* check for duplicates *)
      (IntSet.add age age_set,d)) state (IntSet.empty,false)

  (* For a given set of ages filled by the program, return the number of *)
  (* cache states that can be distinguished by the adversary *)
  let num_poss_states env ages = 
      IntListSet.fold (fun istate num -> 
        if IntSet.equal (complement env.assoc istate) ages then num+1 
        else num) env.poss_init_ages 0 

    
  (* Returns a list of concretizations corresponding to one cache set [cset]. *)
  (* Each concretization is a NumMap, mapping blocks to ages *)
  let concretize_set env cset =
    (* cartesian is the Cartesian product of ages. Each tuple is a NumMap,
       maping blocks to ages *)
    let cartesian =
      let addtoone b m =
	List.map (fun a -> NumMap.add b a m) (A.get_values env.ages b) in
      let addtoall b concs =
	List.concat (List.map (addtoone b) concs) in
      NumSet.fold addtoall cset [NumMap.empty] in
    (* filters out blocks with impossible age combinations: 
       "holes" and duplicates *)
    let possible state =   
      let state_ages, duplicate = get_ages env state in
      (not duplicate) && (num_poss_states env state_ages > 0)
    in List.filter possible cartesian


    
  (* Give the abstraction of [concr] *)
  let abstract_set env concr = 
    let abstr,_ = 
      List.fold_left (fun (ages,first_time) state -> 
        (* Set ages of current concrete state *)
        let nages = NumMap.fold (fun block age nages -> 
          A.set_var nages block age) state ages in 
        (* We overwrite the first value and join afterwards *)
        if first_time then (nages,false) else (A.join ages nages,false)
        ) (env.ages,true) concr in
    abstr
  
  
  (*** Counting valid states ***)
  
  let sum = List.fold_left ( + ) 0


  (*** Counts the number of observations a disjoint memory space
       adversary can make on a single cache set ***)
  let count_set_disjoint env set =
    let concr = concretize_set env set in
    let age_sets = List.fold_left (fun set state -> 
      IntSetSet.add (fst (get_ages env state)) 
        set) IntSetSet.empty concr in
    let observables = List.rev_map (fun ages -> num_poss_states env ages)
      (IntSetSet.elements age_sets) in
    sum observables

  (*** Counts the number of observations a shared memory space
       adversary can make on a single cache set ***)
  let count_set_shared env set =
    let concr = concretize_set env set in
    let observables = List.rev_map
      (fun cs -> num_poss_states env (fst (get_ages env cs))) concr in
    sum observables
  
  (*** Lifts counting from sets to cache states by taking the
       product ***)
  let count_caches env adversary =
    let sets =  IntMap.fold (fun _ x xs -> x::xs) env.cache_sets [] in
    let set_counter = match adversary with
      | Disjoint -> count_set_disjoint env
      | Shared -> count_set_shared env
    in Utils.prod (List.rev_map (fun x -> Int64.of_int (set_counter x)) sets)

  let rr_state_way_set state =
    IntMap.fold
      (fun way _ acc -> IntSet.add way acc)
      state.rr_way_blocks
      IntSet.empty

  module RRDisjointObsOrd = struct
    type t = int * int list
    let compare = Pervasives.compare
  end

  module RRDisjointObsSet = Set.Make(RRDisjointObsOrd)

  let rr_disjoint_signature state =
    let ways =
      IntMap.fold (fun way _ acc -> way :: acc) state.rr_way_blocks []
    in
    (state.rr_next_way, ways)

  let count_rr_set_shared env states =
    RRSetStateSet.fold
      (fun state total ->
        total + num_poss_states env (rr_state_way_set state))
      states 0

  let count_rr_set_disjoint env states =
    let observations =
      RRSetStateSet.fold
        (fun state acc ->
          RRDisjointObsSet.add (rr_disjoint_signature state) acc)
        states RRDisjointObsSet.empty
    in
    RRDisjointObsSet.fold
      (fun (_, ways) total ->
        total + num_poss_states env (IntSet.of_list ways))
      observations 0

  let count_rr_caches env adversary =
    let set_counter = match adversary with
      | Shared -> count_rr_set_shared env
      | Disjoint -> count_rr_set_disjoint env
    in
    let counts =
      IntMap.fold
        (fun _ states acc ->
          (Int64.of_int (set_counter states)) :: acc)
        env.rr_states
        []
    in
    Utils.prod counts

  (* Random replacement observer. *)
  module RandSharedObsOrd = struct
    type t = (int * int64) list
    let compare = Pervasives.compare
  end

  module RandSharedObsSet = Set.Make(RandSharedObsOrd)

  module RandDisjointObsOrd = struct
    type t = int list
    let compare = Pervasives.compare
  end

  module RandDisjointObsSet = Set.Make(RandDisjointObsOrd)

  let rand_shared_signature state =
    IntMap.bindings state.rand_way_blocks

  let rand_disjoint_signature state =
    IntMap.fold (fun way _ acc -> way :: acc) state.rand_way_blocks []

  let count_rand_set_shared states =
    let observations =
      RandSetStateSet.fold
        (fun state acc ->
          RandSharedObsSet.add (rand_shared_signature state) acc)
        states RandSharedObsSet.empty
    in
    RandSharedObsSet.cardinal observations

  let count_rand_set_disjoint states =
    let observations =
      RandSetStateSet.fold
        (fun state acc ->
          RandDisjointObsSet.add (rand_disjoint_signature state) acc)
        states RandDisjointObsSet.empty
    in
    RandDisjointObsSet.cardinal observations

  let count_rand_caches env adversary =
    let set_counter = match adversary with
      | Shared -> count_rand_set_shared
      | Disjoint -> count_rand_set_disjoint
    in
    let counts =
      IntMap.fold
        (fun _ states acc ->
          (Int64.of_int (set_counter states)) :: acc)
        env.rand_states
        []
    in
    Utils.prod counts

  (* BIP observations using explicit correlated LRU-stack states.
     Each NumMap contains only program blocks currently resident in one set,
     mapped to their exact LRU age. Initial/unknown blocks occupy all other
     ages and are accounted for by [num_poss_states]. *)
  let bip_state_age_set state =
    NumMap.fold (fun _ age acc -> IntSet.add age acc) state IntSet.empty

  let count_bip_set_shared env states =
    SetState.fold
      (fun state total ->
        total + num_poss_states env (bip_state_age_set state))
      states 0

  let count_bip_set_disjoint env states =
    let age_sets =
      SetState.fold
        (fun state acc -> IntSetSet.add (bip_state_age_set state) acc)
        states IntSetSet.empty
    in
    IntSetSet.fold
      (fun ages total -> total + num_poss_states env ages)
      age_sets 0

  let count_bip_caches env adversary =
    let set_counter = match adversary with
      | Shared -> count_bip_set_shared env
      | Disjoint -> count_bip_set_disjoint env
    in
    let counts =
      IntMap.fold
        (fun _ states acc ->
          (Int64.of_int (set_counter states)) :: acc)
        env.bip_states []
    in
    Utils.prod counts

  (* BRRIP observations.

     The PRNG belongs to the transition state because it determines future
     insertion decisions, but it is not itself a current cache observation.

     As with BIP, ways that no tracked program block has ever occupied are
     not really "empty" at runtime: they hold some background block loaded
     before analysis began, and the adversary's uncertainty about which
     background block occupies them must be accounted for, exactly as
     [num_poss_states]/[poss_init_ages] does for BIP's occupied-age set.
     [brrip_state_way_set] plays the role BIP's occupied-age set plays:
     since there are exactly [assoc] ways (just as there are exactly
     [assoc] ages), [num_poss_states] applies unchanged.

     Shared-memory adversary:
       Preserve way, program-block identity, and RRPV. States that only
       differ in invisible PRNG history are first deduplicated by their
       observable signature; each distinct signature then gets multiplied
       by the number of ways its untouched ways could be filled by
       background blocks.

     Disjoint-memory adversary:
       Program-block identities are not observable.  Quotient states by the
       multiset of RRPVs currently occupied by program blocks in this set.
       We intentionally keep multiplicity (e.g. [2;2;3] differs from [2;3])
       because BRRIP allows several entries to have the same RRPV. Several
       distinct underlying way-sets can collapse onto the same RRPV
       multiset; each such way-set still contributes its own background
       completion count, so we sum num_poss_states over the distinct
       way-sets seen for a given signature rather than counting the
       signature once. *)
  module BRRIPSharedObsOrd = struct
    type t = (int * int64 * int) list
    let compare = Pervasives.compare
  end

  module BRRIPSharedObsSet = Set.Make(BRRIPSharedObsOrd)

  let brrip_shared_signature state =
    IntMap.fold
      (fun way block acc ->
        (way, block, IntMap.find way state.brrip_way_rrpv) :: acc)
      state.brrip_way_blocks
      []

  let brrip_disjoint_signature state =
    let rrpvs =
      IntMap.fold
        (fun way _ acc ->
          (IntMap.find way state.brrip_way_rrpv) :: acc)
        state.brrip_way_blocks
        []
    in
    List.sort Pervasives.compare rrpvs

  (* Ways currently occupied by a tracked program block -- the BRRIP analog
     of BIP's occupied-age set. Used to multiply in the number of ways the
     remaining (untouched) ways could be filled by background blocks. *)
  let brrip_state_way_set state =
    IntMap.fold
      (fun way _ acc -> IntSet.add way acc)
      state.brrip_way_blocks
      IntSet.empty

  let count_brrip_set_shared env states =
    (* Dedup states that differ only in invisible PRNG history, keeping one
       representative way-set per distinct observable signature. *)
    let table =
      BRRIPSetStateSet.fold
        (fun state acc ->
          let sig_ = brrip_shared_signature state in
          if List.mem_assoc sig_ acc then acc
          else (sig_, brrip_state_way_set state) :: acc)
        states []
    in
    List.fold_left
      (fun total (_, ways) -> total + num_poss_states env ways)
      0 table

  let count_brrip_set_disjoint env states =
    (* Group by observable RRPV-multiset signature, but keep every distinct
       way-set seen under that signature: each contributes its own
       background-completion count. *)
    let table =
      BRRIPSetStateSet.fold
        (fun state acc ->
          let sig_ = brrip_disjoint_signature state in
          let ways = brrip_state_way_set state in
          let prev_ways =
            try List.assoc sig_ acc with Not_found -> IntSetSet.empty
          in
          (sig_, IntSetSet.add ways prev_ways) :: (List.remove_assoc sig_ acc))
        states []
    in
    List.fold_left
      (fun total (_, way_sets) ->
        IntSetSet.fold
          (fun ways t -> t + num_poss_states env ways)
          way_sets total)
      0 table

  let count_brrip_caches env adversary =
    let set_counter = match adversary with
      | Shared -> count_brrip_set_shared env
      | Disjoint -> count_brrip_set_disjoint env
    in
    let counts =
      IntMap.fold
        (fun _ states acc ->
          (Int64.of_int (set_counter states)) :: acc)
        env.brrip_states
        []
    in
    Utils.prod counts

  (* Legacy interface *)
  let count_cache_states env =
    if env.strategy = RR then
      count_rr_caches env !adversary
    else if env.strategy = RAND then
      count_rand_caches env !adversary
    else if env.strategy = BIP then
      count_bip_caches env !adversary
    else if env.strategy = BRRIP then
      count_brrip_caches env !adversary
    else
      count_caches env !adversary
      

  (* apply function f to all elements of a set of states *)
  let setstate_map f cset = 
    SetState.fold (fun x st -> SetState.add (f x) st) cset SetState.empty
  ;;
	
  (*Function to update all the states in a set*)
  let upd_set c_set base_b assoc strategy permut =
    (*Function to update one cache state*)
    let update_state c =
      (*Get base age*)
      let base_age = NumMap.find base_b c in
      (*Update depending on the case*)
      let upd b n =
	if n = assoc then
	  if b = base_b then 0
	  else assoc
	else
	  if base_age = assoc && base_b <> b then
            match strategy with
            | MRU -> if n = 0 then assoc else n
            | _ -> n+1
	  else 
	    permut assoc base_age n
      in
      (*Modify the ages*)
      NumMap.mapi upd c
    in

    setstate_map update_state c_set
  ;;

  (*** Computes the maximum information leakage of a set of states given
       a set of blocks and a set of flag sets ***)  
  let rec partition c_set blocks assoc strategy permut flags=
    let cardinal = SetState.cardinal c_set in

    (*If the knowledge set is singleton or empty, finish*)
    if cardinal <= 1 then cardinal
    (*If c_set is in the flags, finish*)
    else if SetSetState.mem c_set flags then 1
					       
    else      
      (*Function to probe with block q*)
      let probe b rmax=
	(*If the leakage is equal to the size of c_set, return rmax*)
	if rmax = cardinal then
	  rmax
	else

	  (*Function that returns true if the block is in the cache*)   
	  let hit c = (NumMap.find b c < assoc) in
	  (*Partition the set into the ones that return hit and miss*)
	  let (cs_h,cs_m) = SetState.partition hit c_set in

	  (*Check for total hits and misses and modify flag set*)
	  let flags_pass =
	    if (SetState.is_empty cs_m) then
	      SetSetState.add cs_h flags
	    else if (SetState.is_empty cs_h) then
	      SetSetState.add cs_m flags
	    else
	      SetSetState.empty
	  in
	  
	  (*Update both subsets*)
	  let cs_h = upd_set cs_h b assoc strategy permut in
	  let cs_m = upd_set cs_m b assoc strategy permut in
          
	  (*Recursive call*)
	  let r_h = partition cs_h blocks assoc strategy permut flags_pass in
	  let r_m = partition cs_m blocks assoc strategy permut flags_pass in

	  (*Keep the maximum*)
	  max rmax (r_h+r_m)
      in

      (*Iterate over all blocks*)
      NumSet.fold probe blocks 1
  ;;  

  (*** Counts the number of knowledge sets a shared memory space
       adversary can make on a single cache set ***)  
  let count_set_leakage env adversary set =
    let assoc = env.assoc in
    let strategy = env.strategy in
    let permut = get_permutation strategy in
    let concr = concretize_set env set in

    (*Function to create abstract blocks*)
    let rec extra_address addr a =
      match a with
	0 -> []
       |a ->
	 (*Compute a new address*)
	 let addr = Int64.sub addr (Int64.one) in
	  addr :: (extra_address addr (a-1))
    in
    (*Produce assoc abstract blocks with negative addresses*)
    let abs_blocks = extra_address Int64.zero assoc in

    (*Function to include the abstract blocks in every mapping*)
    let add_abs_blocks cs =
      (*Get the ages already filled*)
      let ages = fst (get_ages env cs) in
      (*Create a set of states with abstract blocks in the ages given by alist*)
      let create_set_state alist =
	(*If the mapping of abstract blocks is consistent with the filled ages*)
	if IntSet.equal (complement assoc alist) ages then
	  (*Create a set of states with the map plus the abstract blocks in *)
	  (*their corresponding ages given in alist*)
          SetState.singleton (List.fold_left2 (fun cs b a -> NumMap.add b a cs) cs abs_blocks alist)
	(*If the mapping is not consistent return an empty set of states*)
	else SetState.empty
      in
      (*Create a set of states with all valid combinations of abstract blocks for a given state*)
      IntListSet.fold (fun alist c_set -> SetState.union (create_set_state alist) c_set) env.poss_init_ages SetState.empty
    in

    (*Create set of states*)
    let states = List.fold_left (fun c_set cs -> SetState.union c_set (add_abs_blocks cs)) SetState.empty concr in
    (*Create set of blocks*)
    let blocks = match adversary with
	Shared   -> NumSet.union set (NumSet.of_list abs_blocks)
       |Disjoint -> NumSet.of_list abs_blocks
    in
    (*Compute maximum information leakage*)
    partition states blocks assoc strategy permut SetSetState.empty
  ;;

  (*** Lifts counting from sets to cache states by taking the
       product ***)
  let count_cache_leakage env adversary =
    let sets =  IntMap.fold (fun _ x xs -> x::xs) env.cache_sets [] in
    let set_counter = count_set_leakage env adversary in
    Utils.prod (List.rev_map (fun x -> Int64.of_int (set_counter x)) sets)
  ;;
					    
  (*** Printing ***)

     
  let print_addr_set fmt = NumSet.iter (fun a -> Format.fprintf fmt "%Lx " a)

  (* [print num] prints [num], which should be positive, as well as how many
     bits it is. If [num <= 0], print an error message *)
  let print_num fmt num =
    let strnum = string_of_big_int num in
    if gt_big_int num zero_big_int then 
      Format.fprintf fmt "%s, (%f bits)\n" strnum (Utils.log2 num)
    else begin
      Format.fprintf fmt "counting not possible\n";
      if get_log_level CacheLL = Debug then
        Format.fprintf fmt  "Number of configurations %s\n" strnum;
    end
  
  let print_rr_state fmt state =
    Format.fprintf fmt "next=%d [" state.rr_next_way;
    IntMap.iter
      (fun way block ->
        Format.fprintf fmt " way%d=%Lx" way block)
      state.rr_way_blocks;
    Format.fprintf fmt " ]"

  let print_rand_state fmt state =
    Format.fprintf fmt "mt_index=%d [" state.rand_prng.mt_index;
    IntMap.iter
      (fun way block ->
        Format.fprintf fmt " way%d=%Lx" way block)
      state.rand_way_blocks;
    Format.fprintf fmt " ]"

  let print_bip_state fmt state =
    Format.fprintf fmt "[";
    NumMap.iter
      (fun block age -> Format.fprintf fmt " %Lx(age=%d)" block age)
      state;
    Format.fprintf fmt " ]"

  let print_brrip_state fmt state =
    Format.fprintf fmt "[";
    IntMap.iter
      (fun way block ->
        let rrpv = try IntMap.find way state.brrip_way_rrpv with Not_found -> -1 in
        Format.fprintf fmt " way%d=%Lx(rrpv=%d)" way block rrpv)
      state.brrip_way_blocks;
    Format.fprintf fmt " ]"

  let print fmt env =
    Format.fprintf fmt "Final cache state:\n";

    if env.strategy = RR then begin
      Format.fprintf fmt "@[Round-robin states:@.";
      IntMap.iter
        (fun set states ->
          Format.fprintf fmt "@;Set %3d:@." set;
          RRSetStateSet.iter
            (fun state ->
              Format.fprintf fmt "  %a@." print_rr_state state)
            states)
        env.rr_states;
      Format.fprintf fmt "@]";
      Format.printf "@.";
    end else if env.strategy = RAND then begin
      Format.fprintf fmt "@[Pseudorandom MT19937 states:@.";
      IntMap.iter
        (fun set states ->
          Format.fprintf fmt "@;Set %3d:@." set;
          RandSetStateSet.iter
            (fun state ->
              Format.fprintf fmt "  %a@." print_rand_state state)
            states)
        env.rand_states;
      Format.fprintf fmt "@]";
      Format.printf "@.";
    end else if env.strategy = BIP then begin
      Format.fprintf fmt "@[BIP states:@.";
      IntMap.iter
        (fun set states ->
          Format.fprintf fmt "@;Set %3d:@." set;
          SetState.iter
            (fun state -> Format.fprintf fmt "  %a@." print_bip_state state)
            states)
        env.bip_states;
      Format.fprintf fmt "@]";
      Format.printf "@.";
    end else if env.strategy = BRRIP then begin
      Format.fprintf fmt "@[BRRIP states:@.";
      IntMap.iter
        (fun set states ->
          Format.fprintf fmt "@;Set %3d:@." set;
          BRRIPSetStateSet.iter
            (fun state -> Format.fprintf fmt "  %a@." print_brrip_state state)
            states)
        env.brrip_states;
      Format.fprintf fmt "@]";
      Format.printf "@.";
    end else begin
      Format.fprintf fmt "@[Set: addr1 in {age1,age2,...} addr2 in ...@.";
      IntMap.iter (fun i all_elts ->
          if not (NumSet.is_empty all_elts) then begin
            Format.fprintf fmt "@;%3d: " i;
            NumSet.iter (fun elt -> 
              Format.fprintf fmt "%Lx" elt;
              Format.fprintf fmt " in {%s} @,"
                (String.concat "," (List.map
                  string_of_int (A.get_values env.ages elt)))
              ) all_elts;
            Format.fprintf fmt "@]"
          end
        ) env.cache_sets;
      Format.printf "@.";
    end;
      
    (*Results for shared memory*)
    let sh_num =
      if env.strategy = RR then count_rr_caches env Shared
      else if env.strategy = RAND then count_rand_caches env Shared
      else if env.strategy = BIP then count_bip_caches env Shared
      else if env.strategy = BRRIP then count_brrip_caches env Shared
      else count_caches env Shared
    in
    Format.fprintf fmt "\nNumber of valid cache configurations (shared memory): ";
    print_num fmt sh_num;
    if !compute_leakage && env.strategy <> RR && env.strategy <> RAND && env.strategy <> BIP && env.strategy <> BRRIP then begin
      let sh_leak = count_cache_leakage env Shared in
      Format.fprintf fmt "Number of distinguishable subsets (shared memory): ";
      print_num fmt sh_leak
    end;

    (*Results for disjoint memory*)
    let dj_num =
      if env.strategy = RR then count_rr_caches env Disjoint
      else if env.strategy = RAND then count_rand_caches env Disjoint
      else if env.strategy = BIP then count_bip_caches env Disjoint
      else if env.strategy = BRRIP then count_brrip_caches env Disjoint
      else count_caches env Disjoint
    in
    Format.fprintf fmt "\nNumber of valid cache configurations (disjoint memory): ";
    print_num fmt dj_num;
    if !compute_leakage && env.strategy <> RR && env.strategy <> RAND && env.strategy <> BIP && env.strategy <> BRRIP then begin
      let dj_leak = count_cache_leakage env Disjoint in
      Format.fprintf fmt "Number of distinguishable subsets (disjoint memory): ";
      print_num fmt dj_leak
    end

    let print_delta c1 fmt c2 = match get_log_level CacheLL with
    | Debug->
      let added_blocks = NumSet.diff c2.handled_addrs c1.handled_addrs
      and removed_blocks = NumSet.diff c1.handled_addrs c2.handled_addrs in
      if not (NumSet.is_empty added_blocks) then Format.fprintf fmt
        "Blocks added to the cache: %a@;" print_addr_set added_blocks;
      if not (NumSet.is_empty removed_blocks) then Format.fprintf fmt
        "Blocks removed from the cache: %a@;" print_addr_set removed_blocks;
      if c1.ages != c2.ages then begin
            (* this is shallow equals - does it make sense? *)
        Format.fprintf fmt "@;@[<v 0>@[Old ages are %a@]"
          (A.print_delta c2.ages) c1.ages;
            (* print fmt c1; *)
        Format.fprintf fmt "@;@[New ages are %a@]@]"
          (A.print_delta c1.ages) c2.ages;
      end
    | _ -> A.print_delta c2.ages fmt c1.ages
  
  (*** General abstract interpretation functions ***)

  (* Removes a cache line when we know it cannot be in the cache *)
  let remove_block env addr =
    let addr_set = get_set_addr env addr in
    let cset = IntMap.find addr_set env.cache_sets in
    let cset = NumSet.remove addr cset in
    let handled_addrs = NumSet.remove addr env.handled_addrs in
    { env with
      ages = A.delete_var env.ages addr;
      handled_addrs = handled_addrs;
      cache_sets = IntMap.add addr_set cset env.cache_sets;
    }
  

  let join_rr_states r1 r2 =
    IntMap.merge
      (fun _ s1 s2 ->
        match s1, s2 with
        | Some a, Some b -> Some (RRSetStateSet.union a b)
        | Some a, None -> Some a
        | None, Some b -> Some b
        | None, None -> None)
      r1
      r2

  let rr_subseteq r1 r2 =
    IntMap.for_all
      (fun set states1 ->
        try
          let states2 = IntMap.find set r2 in
          RRSetStateSet.subset states1 states2
        with Not_found ->
          false)
      r1

  let join_rand_states r1 r2 =
    IntMap.merge
      (fun _ s1 s2 ->
        match s1, s2 with
        | Some a, Some b -> Some (RandSetStateSet.union a b)
        | Some a, None -> Some a
        | None, Some b -> Some b
        | None, None -> None)
      r1
      r2

  let rand_subseteq r1 r2 =
    IntMap.for_all
      (fun set states1 ->
        try
          let states2 = IntMap.find set r2 in
          RandSetStateSet.subset states1 states2
        with Not_found ->
          false)
      r1

  let join_bip_states r1 r2 =
    IntMap.merge
      (fun _ s1 s2 ->
        match s1, s2 with
        | Some a, Some b -> Some (SetState.union a b)
        | Some a, None -> Some a
        | None, Some b -> Some b
        | None, None -> None)
      r1 r2

  let bip_subseteq r1 r2 =
    IntMap.for_all
      (fun set states1 ->
        try
          let states2 = IntMap.find set r2 in
          SetState.subset states1 states2
        with Not_found -> false)
      r1

  let join_brrip_states r1 r2 =
    IntMap.merge
      (fun _ s1 s2 ->
        match s1, s2 with
        | Some a, Some b -> Some (BRRIPSetStateSet.union a b)
        | Some a, None -> Some a
        | None, Some b -> Some b
        | None, None -> None)
      r1 r2

  let brrip_subseteq r1 r2 =
    IntMap.for_all
      (fun set states1 ->
        try
          let states2 = IntMap.find set r2 in
          BRRIPSetStateSet.subset states1 states2
        with Not_found -> false)
      r1

  let join c1 c2 =
    assert ((c1.assoc = c2.assoc) && 
      (c1.num_sets = c2.num_sets));
    let handled_addrs = NumSet.union c1.handled_addrs c2.handled_addrs in
    let cache_sets = IntMap.merge 
      (fun _ x y ->
        match x,y with
        | Some cset1, Some cset2 ->
           Some (NumSet.union cset1 cset2)
        | Some cset1, None -> Some cset1
        | None, Some cset2 -> Some cset2
        | None, None -> None 
      ) c1.cache_sets c2.cache_sets in
    let assoc = c1.assoc in
    let haddr_1minus2 = NumSet.diff c1.handled_addrs c2.handled_addrs in
    let haddr_2minus1 = NumSet.diff c2.handled_addrs c1.handled_addrs  in
    (* add missing variables to ages *)
    let ages1 = NumSet.fold (fun addr c_ages ->
      A.set_var c_ages addr assoc) haddr_2minus1 c1.ages in
    let ages2 = NumSet.fold (fun addr c_ages ->
      A.set_var c_ages addr assoc) haddr_1minus2 c2.ages in
    let ages = A.join ages1 ages2 in
    let rr_states = join_rr_states c1.rr_states c2.rr_states in
    let rand_states = join_rand_states c1.rand_states c2.rand_states in
    let bip_states = join_bip_states c1.bip_states c2.bip_states in
    let brrip_states = join_brrip_states c1.brrip_states c2.brrip_states in
    { c1 with
      ages = ages;
      handled_addrs = handled_addrs;
      cache_sets = cache_sets;
      rr_states = rr_states;
      rand_states = rand_states;
      bip_states = bip_states;
      brrip_states = brrip_states;
    }
  
  let widen c1 c2 = 
    join c1 c2

  let subseteq c1 c2 =
    assert 
      ((c1.assoc = c2.assoc) && (c1.num_sets = c2.num_sets));
    (NumSet.subset c1.handled_addrs c2.handled_addrs) &&
    (A.subseteq c1.ages c2.ages) &&
    (IntMap.for_all (fun addr vals ->
      if IntMap.mem addr c2.cache_sets
      then NumSet.subset vals (IntMap.find addr c2.cache_sets)
      else false
     ) c1.cache_sets) &&
    (rr_subseteq c1.rr_states c2.rr_states) &&
    (rand_subseteq c1.rand_states c2.rand_states) &&
    (bip_subseteq c1.bip_states c2.bip_states) &&
    (brrip_subseteq c1.brrip_states c2.brrip_states)
  
  
  let remove_not_cached env block =
    if (A.get_values env.ages block) = [env.assoc] then
      remove_block env block
    else env

  (*** Cache update ***)
  
  let get_cset env block = 
    let set_addr = get_set_addr env block in
    IntMap.find set_addr env.cache_sets

  (*** Round-robin update functions ***)

  (* Test whether a concrete RR state currently contains [block]. *)
  let rr_state_contains block state =
    IntMap.fold
      (fun _ cached_block found ->
        found || cached_block = block)
      state.rr_way_blocks
      false

  (* Apply one allocating RR miss to one concrete RR state. *)
  let rr_miss_state assoc block state =
    let way = state.rr_next_way in
    {
      rr_next_way = (way + 1) mod assoc;
      rr_way_blocks = IntMap.add way block state.rr_way_blocks;
    }

  (* Apply an RR miss to every possible state at this cache set. *)
  let rr_apply_misses assoc block states =
    RRSetStateSet.fold
      (fun state result ->
        RRSetStateSet.add
          (rr_miss_state assoc block state)
          result)
      states
      RRSetStateSet.empty

  (* Keep the generic CacheAudit address bookkeeping in sync.
     RR replacement itself never consults [ages]. *)
  let rr_register_block env block =
    if NumSet.mem block env.handled_addrs then
      env
    else
      let set_addr = get_set_addr env block in
      let cset = IntMap.find set_addr env.cache_sets in
      {
        env with
        ages = A.set_var env.ages block env.assoc;
        handled_addrs = NumSet.add block env.handled_addrs;
        cache_sets =
          IntMap.add set_addr (NumSet.add block cset) env.cache_sets;
      }

  (* Round-robin access. Hits leave the pointer unchanged. Read misses
     allocate into rr_next_way and advance it modulo associativity.
     Write misses obey the existing no-write-allocate policy. *)
  let rr_touch env block rw =
    let env = rr_register_block env block in
    let set_addr = get_set_addr env block in
    let states = IntMap.find set_addr env.rr_states in
    let hit_states, miss_states =
      RRSetStateSet.partition (rr_state_contains block) states
    in
    let miss_states =
      if rw = Write then
        miss_states
      else
        rr_apply_misses env.assoc block miss_states
    in
    let new_states = RRSetStateSet.union hit_states miss_states in
    {
      env with
      rr_states = IntMap.add set_addr new_states env.rr_states;
    }

  (* RR version of touch_hm, preserving the hit and miss cases separately. *)
  let rr_touch_hm env block rw =
    let env = rr_register_block env block in
    let set_addr = get_set_addr env block in
    let states = IntMap.find set_addr env.rr_states in
    let hit_states, miss_states =
      RRSetStateSet.partition (rr_state_contains block) states
    in
    let miss_states =
      if rw = Write then
        miss_states
      else
        rr_apply_misses env.assoc block miss_states
    in
    let make_result states =
      if RRSetStateSet.is_empty states then
        Bot
      else
        Nb {
          env with
          rr_states = IntMap.add set_addr states env.rr_states;
        }
    in
    (make_result hit_states, make_result miss_states)

  (*** Random replacement update functions ***)

  (* Test whether a concrete random-replacement state contains [block]. *)
  let rand_state_contains block state =
    IntMap.fold
      (fun _ cached_block found ->
        found || cached_block = block)
      state.rand_way_blocks
      false

  let rand_miss_state assoc block state =
    let next_prng, value = mt_next state.rand_prng in
    let way = mt_way assoc value in
    {
      rand_prng = next_prng;
      rand_way_blocks = IntMap.add way block state.rand_way_blocks;
    }

  let rand_apply_misses assoc block states =
    RandSetStateSet.fold
      (fun state result ->
        RandSetStateSet.add
          (rand_miss_state assoc block state)
          result)
      states
      RandSetStateSet.empty

  let rand_touch env block rw =
    let env = rr_register_block env block in
    let set_addr = get_set_addr env block in
    let states = IntMap.find set_addr env.rand_states in
    let hit_states, miss_states =
      RandSetStateSet.partition (rand_state_contains block) states
    in
    let miss_states =
      if rw = Write then
        miss_states
      else
        rand_apply_misses env.assoc block miss_states
    in
    let new_states = RandSetStateSet.union hit_states miss_states in
    {
      env with
      rand_states = IntMap.add set_addr new_states env.rand_states;
    }

  (* RAND version of touch_hm, preserving the hit and miss cases separately. *)
  let rand_touch_hm env block rw =
    let env = rr_register_block env block in
    let set_addr = get_set_addr env block in
    let states = IntMap.find set_addr env.rand_states in
    let hit_states, miss_states =
      RandSetStateSet.partition (rand_state_contains block) states
    in
    let miss_states =
      if rw = Write then
        miss_states
      else
        rand_apply_misses env.assoc block miss_states
    in
    let make_result states =
      if RandSetStateSet.is_empty states then
        Bot
      else
        Nb {
          env with
          rand_states = IntMap.add set_addr states env.rand_states;
        }
    in
    (make_result hit_states, make_result miss_states)

  (*** BRRIP update functions ***)

  let brrip_max_rrpv = (1 lsl brrip_num_bits) - 1

  let brrip_state_contains block state =
    IntMap.fold
      (fun _ cached_block found -> found || cached_block = block)
      state.brrip_way_blocks
      false

  let brrip_find_way block state =
    IntMap.fold
      (fun way cached_block found ->
        match found with
        | Some _ -> found
        | None -> if cached_block = block then Some way else None)
      state.brrip_way_blocks
      None

  let brrip_touch_state state block =
    match brrip_find_way block state with
    | None -> state
    | Some way ->
        let old_rrpv = IntMap.find way state.brrip_way_rrpv in
        let new_rrpv =
          if brrip_hit_priority then 0
          else max 0 (old_rrpv - 1)
        in
        { state with
          brrip_way_rrpv = IntMap.add way new_rrpv state.brrip_way_rrpv;
        }

  let rec first_empty_way assoc way blocks =
    if way >= assoc then None
    else if IntMap.mem way blocks then first_empty_way assoc (way + 1) blocks
    else Some way

  (* gem5's getVictim picks the candidate with the largest current RRPV,
     then raises every RRPV by (max_RRPV - victim_RRPV) so the victim
     reaches max. Ties keep the first candidate. *)
  let brrip_choose_victim assoc state =
    match first_empty_way assoc 0 state.brrip_way_blocks with
    | Some way -> (state, way)
    | None ->
        let victim_way, victim_rrpv =
          let rec loop way best_way best_rrpv =
            if way >= assoc then (best_way, best_rrpv)
            else
              let rrpv = IntMap.find way state.brrip_way_rrpv in
              if rrpv > best_rrpv then loop (way + 1) way rrpv
              else loop (way + 1) best_way best_rrpv
          in
          let r0 = IntMap.find 0 state.brrip_way_rrpv in
          loop 1 0 r0
        in
        let diff = brrip_max_rrpv - victim_rrpv in
        if diff = 0 then (state, victim_way)
        else
          let aged_rrpv =
            IntMap.map (fun r -> min brrip_max_rrpv (r + diff)) state.brrip_way_rrpv
          in
          ({ state with brrip_way_rrpv = aged_rrpv }, victim_way)

  let brrip_insert_state assoc block insert_rrpv state =
    let state, way = brrip_choose_victim assoc state in
    { state with
      brrip_way_blocks = IntMap.add way block state.brrip_way_blocks;
      brrip_way_rrpv = IntMap.add way insert_rrpv state.brrip_way_rrpv;
    }

  let brrip_apply_hits block states =
    BRRIPSetStateSet.fold
      (fun state result ->
        BRRIPSetStateSet.add (brrip_touch_state state block) result)
      states BRRIPSetStateSet.empty

  (* Draw gem5-style BRRIP insertion choice.  gem5 samples uniformly from
     [1,100] and inserts at max_RRPV-1 iff the draw is <= btp; otherwise it
     inserts at max_RRPV.  The PRNG state is part of the BRRIP state so joins
     preserve path-specific random histories instead of using global mutable RNG. *)
  let brrip_sample_insertion state =
    let next_prng, value = mt_next state.brrip_prng in
    let unsigned = Int64.logand (Int64.of_int32 value) 0xffffffffL in
    let draw = 1 + Int64.to_int (Int64.rem unsigned 100L) in
    let insert_rrpv =
      if draw <= brrip_btp then max 0 (brrip_max_rrpv - 1)
      else brrip_max_rrpv
    in
    ({ state with brrip_prng = next_prng }, insert_rrpv)

  let brrip_apply_misses assoc block states =
    BRRIPSetStateSet.fold
      (fun state result ->
        let state, insert_rrpv = brrip_sample_insertion state in
        BRRIPSetStateSet.add
          (brrip_insert_state assoc block insert_rrpv state)
          result)
      states BRRIPSetStateSet.empty

  let brrip_touch env block rw =
    let env = rr_register_block env block in
    let set_addr = get_set_addr env block in
    let states = IntMap.find set_addr env.brrip_states in
    let hit_states, miss_states =
      BRRIPSetStateSet.partition (brrip_state_contains block) states
    in
    let hit_states = brrip_apply_hits block hit_states in
    let miss_states =
      if rw = Write then miss_states
      else brrip_apply_misses env.assoc block miss_states
    in
    let new_states = BRRIPSetStateSet.union hit_states miss_states in
    { env with
      brrip_states = IntMap.add set_addr new_states env.brrip_states;
    }

  let brrip_touch_hm env block rw =
    let env = rr_register_block env block in
    let set_addr = get_set_addr env block in
    let states = IntMap.find set_addr env.brrip_states in
    let hit_states, miss_states =
      BRRIPSetStateSet.partition (brrip_state_contains block) states
    in
    let hit_states = brrip_apply_hits block hit_states in
    let miss_states =
      if rw = Write then miss_states
      else brrip_apply_misses env.assoc block miss_states
    in
    let make_result states =
      if BRRIPSetStateSet.is_empty states then Bot
      else Nb { env with
        brrip_states = IntMap.add set_addr states env.brrip_states;
      }
    in
    (make_result hit_states, make_result miss_states)

  (* Remove the "add_bottom" *)
  let strip_bot = function
    | Bot -> raise Bottom
    | Nb x -> x
  
  
  (* The permutation belonging to a cache miss: age of accessed block is set *)
  (* to 0, ages of other blocks are incremented, unless if age = associativity *)
  let miss_permut assoc accessed_block this_block = 
    if this_block = accessed_block then fun _ -> 0
    else fun age -> if age = assoc then age else succ age
    
  let mru_miss_permut assoc accessed_block this_block =
    if this_block = accessed_block then
      fun _ -> 0
    else
      fun age ->
        if age = 0 then assoc
        else age

  (*** BIP exact-state update functions ***)

  let bip_state_contains block state = NumMap.mem block state

  (* LRU hit: touched block becomes MRU; younger blocks age by one. *)
  let bip_hit_state block state =
    let touched_age = NumMap.find block state in
    NumMap.mapi
      (fun b age ->
        if b = block then 0
        else if age < touched_age then age + 1
        else age)
      state

  (* BIP common insertion: insert at LRU and evict the previous LRU program
     block if there was one. Unknown initial blocks occupy unrepresented ages. *)
  let bip_lru_insert_state assoc block state =
    let lru_age = assoc - 1 in
    let state =
      NumMap.fold
        (fun b age acc ->
          if age = lru_age then acc else NumMap.add b age acc)
        state NumMap.empty
    in
    NumMap.add block lru_age state

  (* BIP rare insertion: ordinary LRU/MRU insertion. All resident program
     blocks age by one; a block that reaches [assoc] is evicted. *)
  let bip_mru_insert_state assoc block state =
    let state =
      NumMap.fold
        (fun b age acc ->
          let age' = age + 1 in
          if age' >= assoc then acc else NumMap.add b age' acc)
        state NumMap.empty
    in
    NumMap.add block 0 state

  let bip_register_block env block = rr_register_block env block

  let bip_touch env block rw =
    let env = bip_register_block env block in
    let set_addr = get_set_addr env block in
    let states = IntMap.find set_addr env.bip_states in
    let new_states =
      SetState.fold
        (fun state acc ->
          if bip_state_contains block state then
            SetState.add (bip_hit_state block state) acc
          else if rw = Write then
            SetState.add state acc
          else
            let acc = SetState.add
              (bip_lru_insert_state env.assoc block state) acc in
            SetState.add
              (bip_mru_insert_state env.assoc block state) acc)
        states SetState.empty
    in
    { env with bip_states = IntMap.add set_addr new_states env.bip_states }

  let bip_touch_hm env block rw =
    let env = bip_register_block env block in
    let set_addr = get_set_addr env block in
    let states = IntMap.find set_addr env.bip_states in
    let hit_states, miss_states =
      SetState.partition (bip_state_contains block) states
    in
    let hit_states = SetState.fold
      (fun state acc -> SetState.add (bip_hit_state block state) acc)
      hit_states SetState.empty
    in
    let miss_states =
      if rw = Write then miss_states
      else
        SetState.fold
          (fun state acc ->
            let acc = SetState.add
              (bip_lru_insert_state env.assoc block state) acc in
            SetState.add
              (bip_mru_insert_state env.assoc block state) acc)
          miss_states SetState.empty
    in
    let make_result states =
      if SetState.is_empty states then Bot
      else Nb { env with bip_states = IntMap.add set_addr states env.bip_states }
    in
    (make_result hit_states, make_result miss_states)

  (* BIP's normal miss inserts at the LRU position.  The old LRU block is
     evicted and all younger blocks keep their current ages. *)
  let bip_lru_miss_permut assoc accessed_block this_block =
    if this_block = accessed_block then
      fun _ -> assoc - 1
    else
      fun age ->
        if age = assoc - 1 then assoc
        else age

  (* The effect of one touch of addr, restricting to the case when addr
     is of age c. c=assoc corresponds to a miss, in which case the age
     of all blocks is incremented -- except for the touched block,
     whose age is set to 0. c < assoc corresponds to a hit, in which
     case a permutation is applied to the ages of all blocks *)
  let one_touch env block block_age rw bip_mru_insert = 
    let strategy = env.strategy in
    let cset = get_cset env block in
    let is_miss = block_age = env.assoc in
    (* Comply to 'no write-allocate' policy: if there is a write-miss, *)
    (* do not put the element into cache *)
    if rw = Write && is_miss then env
    else if (is_miss && !do_concrete_miss) 
      || ((not is_miss) && !do_concrete_hit) then
        let env = if is_miss then env else
          (* make sure no other blocks in the set have ages block_age *)
          let ages = NumSet.fold
            (fun b new_ages ->
              if b = block then new_ages
              else
                let ages_young,ages_old = A.comp new_ages b block in
                (* One of the ages can be bottom, however not both *)
                strip_bot (lift_combine A.join ages_young ages_old)
            ) cset env.ages in
          {env with ages = A.set_var ages block block_age} in
        (* concretize *)
        let concr = concretize_set env cset in
        (* Permute values *)
        (* operation can be infeasible and may take forever;*)
        (* if so, don't use --precise-update *)
        let permut =
          if is_miss then
            match strategy with
            | MRU -> mru_miss_permut
            | BIP when not bip_mru_insert -> bip_lru_miss_permut
            | _ -> miss_permut
          else
            let perm_hit = get_permutation strategy in
            fun assoc _ _ -> perm_hit assoc block_age
        in
        let concr = List.rev_map (NumMap.mapi (permut env.assoc block)) concr in
        (* abstract *)
        {env with ages = abstract_set env concr}
    else (* do abstract-level update *)
      if is_miss then
        if strategy = MRU then
          let nages =
            NumSet.fold
              (fun blck ages ->
                if blck = block then ages
                else
                  A.permute ages
                    (fun age -> if age = 0 then env.assoc else age)
                    blck)
              cset env.ages
          in
          {env with ages = A.set_var nages block 0}
        else if strategy = BIP && not bip_mru_insert then
          let lru_age = env.assoc - 1 in
          let nages =
            NumSet.fold
              (fun blck ages ->
                if blck = block then ages
                else
                  A.permute ages
                    (fun age -> if age = lru_age then env.assoc else age)
                    blck)
              cset env.ages
          in
          {env with ages = A.set_var nages block lru_age}
        else
          let env = {env with ages = A.set_var env.ages block 0} in
          NumSet.fold (fun blck nenv -> 
            if blck = block then nenv else
              let nags = 
                let ags = nenv.ages in
                let nin_cache = List.mem env.assoc (A.get_values ags blck) in
                let ags = A.inc_var ags blck in
                if !do_reduction && 
                  ((strategy = LRU) || (strategy = FIFO)) then
                  (* Optimization: disallow ages >= cardinality of cache set *)
                  let ages_in_cache,_ = A.comp_with_val ags blck (NumSet.cardinal cset) in
                  (* age "associativity" is still possible *)
                  if nin_cache then 
                    let _,ages_nin_cache = A.comp_with_val ags blck env.assoc in
                    strip_bot (lift_combine A.join ages_in_cache ages_nin_cache)
                  else 
                    strip_bot ages_in_cache
                else ags
              in {nenv with ages = nags}
              (* in remove_not_cached {nenv with ages = nags} blck *)
            ) cset env
      else (* abstract-level hit *)
        (* optimize for FIFO *)
        if strategy = FIFO then env 
        else
          (* Permute ages of all blocks != block *)
          let perm = get_permutation strategy in
          let nages = NumSet.fold
              (fun b new_ages ->
                  if b = block then new_ages
                  else
                    let permute_ages ages = match ages with
                      | Bot -> Bot
                      | Nb ags -> Nb (A.permute ags (perm env.assoc block_age) b) in 
                    let ages_young,ages_old = A.comp new_ages b block in
                    let ages_young = permute_ages ages_young in
                    let ages_old =
                      (* optimize for LRU *)
                      if strategy = LRU then ages_old
                      else permute_ages ages_old in
                    (* One of the ages can be bottom, however not both *)
                    strip_bot (lift_combine A.join ages_young ages_old)
              ) cset env.ages in
          (* Permute ages of block *)
          {env with ages = (A.permute nages (perm env.assoc block_age) block)}
  
  (* adds a new address handled by the cache if it's not already handled *)
  (* That works for LRU, FIFO and PLRU *)
  let add_new_address env block =
     (* the block has the default age of associativity *)
     let ages = A.set_var env.ages block env.assoc in
    let set_addr = get_set_addr env block in
    let cset = get_cset env block in
     let h_addrs = NumSet.add block env.handled_addrs in
     let cache_sets = IntMap.add set_addr (NumSet.add block cset) env.cache_sets in
     {env with ages = ages; handled_addrs = h_addrs; cache_sets = cache_sets}
  
  
  (* retuns true if block was handled *)
  let is_handled env block = 
    NumSet.mem block env.handled_addrs
  
  (* Reads or writes an address into cache *)
  let touch env orig_addr rw =
    if get_log_level CacheLL = Debug then Printf.printf "\nWriting cache %Lx" orig_addr;
    (* we cache the block address *)
    let block = get_block_addr env orig_addr in
    if get_log_level CacheLL = Debug then Printf.printf " in block %Lx\n" block;

    if env.strategy = RR then
      rr_touch env block rw
    else if env.strategy = RAND then
      rand_touch env block rw
    else if env.strategy = BIP then
      bip_touch env block rw
    else if env.strategy = BRRIP then
      brrip_touch env block rw
    else
      let env = if is_handled env block then env 
        else add_new_address env block in
      let block_ages = A.get_values env.ages block in
      (try
      let new_env = List.fold_left 
        (fun nenv block_age ->
          match A.exact_val env.ages block block_age with
          | Bot -> raise Bottom
          | Nb xages ->
              let exact_env = {env with ages = xages} in
              let touched =
                if env.strategy = BIP && block_age = env.assoc && rw <> Write then
                  (* The abstract domain does not carry probabilities.  A BIP
                     allocating miss therefore has two reachable successors:
                     the normal LRU insertion (97%) and MRU insertion (3%). *)
                  join
                    (one_touch exact_env block block_age rw false)
                    (one_touch exact_env block block_age rw true)
                else
                  one_touch exact_env block block_age rw false
              in
              lift_combine join nenv (Nb touched)
        ) Bot block_ages in
      strip_bot new_env
      with Bottom -> assert false) (* Touch shouldn't produce bottom *)

  (* Same as touch, but returns two possible configurations, one for the hit and the second for the misses *)
  let touch_hm env orig_addr rw = 
    assert (orig_addr >= 0L);
    let block = get_block_addr env orig_addr in

    if env.strategy = RR then
      rr_touch_hm env block rw
    else if env.strategy = RAND then
      rand_touch_hm env block rw
    else if env.strategy = BIP then
      bip_touch_hm env block rw
    else if env.strategy = BRRIP then
      brrip_touch_hm env block rw
    else
      let env = if is_handled env block then env 
        else add_new_address env block in
      (* ages_in is the set of ages for which there is a hit *)
      let ages_in, ages_out = 
          A.comp_with_val env.ages block env.assoc in
      let t a = match a with Bot -> Bot 
                | Nb a -> Nb(touch {env with ages=a} orig_addr rw)
      in
      (t ages_in, t ages_out)
   
  (* For this domain, we don't care about time *)
  let elapse env d = env
  
end