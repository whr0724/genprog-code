(* 
 * Program Repair Prototype (v2) 
 *
 * Search Strategies include: 
 *  -> Brute Force (e.g., all distance-one edits)
 *  -> Genetic Programming (e.g., ICSE'09)
 *     => delete, append and swap based on fault localization
 *     => crossover: none, one point, two point, uniform, ...
 *)
open Printf
open Global
open Fitness
open Rep

(*Global(ish) variables necessary for splitting up the search space, recording
  the total number of generations and variants evaluated before exit (respectively)*)
let compnumber = ref 1
let totgen = ref (-1)
let varnum = ref 0

let weight_compare (stmt,prob) (stmt',prob') =
    if prob = prob' then compare stmt stmt' 
    else compare prob' prob 

(* transform a list of variants into a listed of fitness-evaluated
 * variants *) 
let calculate_fitness pop =  
  List.map (fun variant -> begin
    varnum := succ !varnum;
    (variant, test_all_fitness variant)
  end ) pop

let generations = ref 10
let popsize = ref 40 
let mutp = ref 0.05
let subatom_mutp = ref 0.5
let subatom_constp = ref 0.5
let crossp = ref 0.5
let promut = ref 0 
let unit_test = ref false
let incoming_pop = ref "" 
let distributed = ref false
let variants_exchanged = ref 5
let diversity_selection = ref false
let num_comps = ref 2
let split_search = ref false
let gen_per_exchange = ref 1
let network_dist = ref false
 
let _ = 
  options := !options @ [
  "--generations", Arg.Set_int generations, "X use X genetic algorithm generations";
  "--popsize", Arg.Set_int popsize, "X variant population size";
  "--mutp", Arg.Set_float mutp, "X use X as mutation rate";	
  "--promut", Arg.Set_int promut, "X make X mutations per 'mutate' call";	
  "--subatom-mutp", Arg.Set_float subatom_mutp, "X use X as subatom mutation rate";	
  "--subatom-constp", Arg.Set_float subatom_constp, "X use X as subatom constant rate";	
  "--crossp", Arg.Set_float crossp, "X use X as crossover rate";
  "--unit_test", Arg.Set unit_test, " Do a test?";
  "--distributed", Arg.Set distributed, " Enable distributed GA mode" ;
  "--num-comps", Arg.Set_int num_comps, "X Distributed: Number of computers to simulate" ;
  "--split-search", Arg.Set split_search, " Distributed: Split up the search space" ;
  "--diversity-selection", Arg.Set diversity_selection, " Distributed: Use diversity for exchange";
  "--variants-exchanged", Arg.Set_int variants_exchanged, "X Distributed: Number of variants exchanged" ;
  "--gen-per-exchange", Arg.Set_int gen_per_exchange, "X Distributed: Number of generations between exchanges" ;
  "--network-distributed", Arg.Set network_dist, " Uses the distributed algorithm.";

] 

(*************************************************************************
 *************************************************************************
                     Distributed computation
 *************************************************************************
 *************************************************************************)
(* Various helper functions*)

(* Parses messages received from other computers and turns them into reps.
   Variants are separated by a period, '.', and mutations are separated by a space, ' '*)
let message_parse orig msg =
  (* Splits into a list of history lists *)
  let varlst = lmap (fun str -> 
    Str.split (Str.regexp_string " ") str
  ) (Str.split (Str.regexp_string ".") msg) in

    (* Turns said list into a list of variants *)
    let variantlist lst =
      lmap 
	(fun history ->
	  lfoldl
	    (fun rep ->
	      fun hist -> begin
		let change = hist.[0] in
		  match change with
		  | 'd' ->
		    let num = (int_of_string (String.sub hist 2 ((String.index hist ')')-2))) in
		      rep#delete num; rep
		  | 'a' ->
		    let tmp = (String.index hist ',') in
		    let num1 = (int_of_string (String.sub hist 2 (tmp-2))) in
		    let num2 = (int_of_string (String.sub hist (tmp+1) ((String.index hist ')')-tmp-1))) in
		      rep#append num1 num2; rep
		  | 's' ->
		    let tmp = (String.index hist ',') in
		    let num1 = (int_of_string (String.sub hist 2 (tmp-2))) in
		    let num2 = (int_of_string (String.sub hist (tmp+1) ((String.index hist ')')-tmp-1))) in
		      rep#swap num1 num2; rep
		  | 'x' -> 
		    debug "Hit a crossover\n";
		    rep
		  |  _  -> 
		    debug "Error: This is not a variant, it is:  %s\n" hist;
		    rep
	      end
	    ) (orig#copy()) (List.rev history)) lst
    in
      (* Returns variant list with the variants associated fitness *)
      (calculate_fitness (variantlist varlst))


(* Creates the message that the function above parses *)
let make_message lst = 
  String.concat "." (lmap (fun (ele,fit) -> String.concat " " (ele#get_history())) lst)

(* Chooses variants based on diversity metrics instead of just fitness,
   if the diversity-selection option is enabled *)
let choose_by_diversity orig lst =
  let histlist = lmap (fun (ele,fit) -> (ele,fit),ele#get_history()) lst in
    
  let setlist =
    lmap (fun (ele,history) -> 
      ele,lfoldl
	(fun ele_set ->
	  fun hist ->
	    StringSet.add hist ele_set)
	(StringSet.empty) history
    ) histlist
  in
    
  (* Add them all to a master set *)
  let allset = 
    lfoldl
      (fun allset ->
	fun (_,oneset) ->
	  StringSet.union allset oneset)
      (StringSet.empty) setlist
  in
  (* Look at which variant has the most changes different from other chosen variants *)
  let rec collect_variants allset setlist sofar =
    (* assumes that !variants_exchanged <= List.length *)
    if sofar = !variants_exchanged then [] 
    else begin
      let sorted = 
	lsort (fun (_,_,a) (_,_,b) -> compare b a)
	  (lmap 
	     (fun (ele,oneset) -> 
	       let intersection = StringSet.inter oneset allset in
		 ele,intersection,StringSet.cardinal intersection)
	     setlist)
      in
      let element,changeset,card = List.hd sorted in
	if card > 0 then begin
	  (*let a,b = element in
	   debug "Variant: %s\n" (a#name ());*)
	  element :: 
	    (collect_variants 
	       (StringSet.diff allset changeset) 
	       (lmap (fun (a,b,_) -> a,b) (List.tl sorted))
	       (sofar + 1))
	end
	else 
	  (* If there are no non-taken, non-original variants left, we just
	     make the rest of them originals *)
	  let fit = float_of_int !pos_tests in
	    lmap (fun _ -> begin
	      (* debug "Variant: %s\n" (orig#name ());*)
	      orig#copy(),fit
	    end) (1 -- (!variants_exchanged - sofar))
    end
  in
    collect_variants allset setlist 0

(* Gets a message with the best variants from lst and a list of all but the worst*)
let get_exchange_network orig lst =
  let lst = List.sort (fun (_,f) (_,f') -> compare f' f) lst in
    if (!popsize == !variants_exchanged) then (make_message lst, [])
    else
      if !diversity_selection then
	if (!popsize / 2 < !variants_exchanged) then
	  ((make_message (choose_by_diversity orig lst)), (first_nth lst (!popsize - !variants_exchanged)))
	else
	  ((make_message (choose_by_diversity orig (first_nth lst (!variants_exchanged * 2)))),
	   (first_nth lst (!popsize - !variants_exchanged)))
      else 
	((make_message (first_nth lst !variants_exchanged)), (first_nth lst (!popsize - !variants_exchanged)))

(* Gets a list with the best variants from lst1 and all, but the worst of lst2 *)
let get_exchange orig lst1 lst2 =
  let lst1 = List.sort (fun (_,f) (_,f') -> compare f' f) lst1 in
  let lst2 = List.sort (fun (_,f) (_,f') -> compare f' f) lst2 in
    if (!popsize == !variants_exchanged) then lst1
    else
      if !diversity_selection then
	if (!popsize / 2 < !variants_exchanged) then
	  (choose_by_diversity orig lst1) @ (first_nth lst2 (!popsize - !variants_exchanged))
	else
	  (choose_by_diversity orig (first_nth lst1 (!variants_exchanged * 2))) @  (first_nth lst2 (!popsize - !variants_exchanged))
      else 
	(first_nth lst1 !variants_exchanged) @ (first_nth lst2 (!popsize - !variants_exchanged))
	  
(* Exchange function: Picks the best variants to trade and tosses out the worst *)
let exchange orig poplist =
  let return = ref [] in
    for comps = 1 to !num_comps-1 do
      return :=  (get_exchange orig (List.nth poplist comps) (List.nth poplist (comps-1))) :: !return
    done;
    return := (get_exchange orig (List.nth poplist 0) (List.nth poplist (!num_comps-1))) :: !return;
    !return


(*************************************************************************
 *************************************************************************
                     Brute Force: Try All Single Edits
 *************************************************************************
 *************************************************************************)

let brute_force_1 (original : 'a Rep.representation) incoming_pop = 
  debug "search: brute_force_1 begins\n" ; 
  if incoming_pop <> [] then begin
    debug "search: incoming population IGNORED\n" ; 
  end ; 
  let fault_localization = original#get_fault_localization () in 
  let fault_localization = List.sort weight_compare fault_localization in 
  let fix_localization = original#get_fix_localization () in 
  let fix_localization = List.sort weight_compare fix_localization in 
  let worklist = ref [] in 

  (* first, try all single deletions *) 
  List.iter (fun (atom,weight) ->
    (* As an optimization, rather than explicitly generating the
     * entire variant in advance, we generate a "thunk" (or "future",
     * or "promise") to create it later. This is handy because there
     * might be over 100,000 possible variants, and we want to sort
     * them by weight before we actually instantiate them. *) 
    let thunk () = 
      let rep = original#copy () in 
      rep#delete atom; 
      rep
    in 
    worklist := (thunk,weight) :: !worklist ; 
  ) fault_localization ; 
  debug "search: brute: %d deletes\n" 
    (List.length fault_localization) ; 

  (* second, try all single appends *) 
  let append_counter = ref 0 in 
  List.iter (fun (dest,w1) ->
    let allowed = lmap fst (WeightSet.elements (original#append_sources dest)) in 
    List.iter (fun (src,w2) -> 
      if lmem src allowed then begin 
        let thunk () = 
          let rep = original#copy () in 
          rep#append dest src; 
          rep 
        in 
        incr append_counter ; 
        worklist := (thunk, w1 *. w2 *. 0.9) :: !worklist ; 
      end
    ) fix_localization 
  ) fault_localization ;  
  debug "search: brute: %d appends (out of %d)\n" 
    !append_counter
    ((List.length fault_localization) * (List.length fix_localization)) ; 

  (* third, try all single swaps *) 
  let swap_counter = ref 0 in 
  List.iter (fun (dest,w1) ->
    let allowed = original#swap_sources dest in 
    List.iter (fun (src,w2) -> 
      if WeightSet.mem (src,1.0) allowed && dest <> src then begin (* swap X with X = no-op *) 
        let thunk () = 
          let rep = original#copy () in 
          rep#swap dest src;
          rep
        in 
        incr swap_counter ; 
        worklist := (thunk, w1 *. w2 *. 0.8) :: !worklist ; 
      end 
    ) fault_localization 
  ) fault_localization ;  
  debug "search: brute: %d swaps (out of %d)\n" 
    !swap_counter
    ((List.length fault_localization) * (List.length fault_localization)) ; 

  (* fourth, try subatom mutations *) 
  let sub_counter = ref 0 in 
  if original#subatoms && !use_subatoms then begin
    List.iter (fun (dest,w1) ->
      let subs = original#get_subatoms dest in 
      for sub_idx = 0 to pred (List.length subs) do
        let thunk () = 
          let rep = original#copy () in 
          rep#replace_subatom_with_constant dest sub_idx ;
          rep
        in 
        incr sub_counter ; 
        worklist := (thunk, w1 *. 0.9) :: !worklist ; 
      done 
    ) fault_localization ; 
  end ; 
  debug "search: brute: %d subatoms\n" 
    !sub_counter;

  (* fifth, try subatom swaps *) 
  let sub_counter = ref 0 in 
  if original#subatoms && !use_subatoms then begin
    List.iter (fun (dest,w1) ->
      let dests = original#get_subatoms dest in 
      let num_dest_subatoms = List.length dests in 
      List.iter (fun (src,w2) -> 
        let subs = original#get_subatoms src in 
        List.iter (fun subatom ->
          for sub_idx = 0 to pred num_dest_subatoms do 
            let thunk () = 
              let rep = original#copy () in 
              rep#replace_subatom dest sub_idx subatom ;
              rep
            in 
            incr sub_counter ; 
            worklist := (thunk, w1 *. 0.9) :: !worklist ; 
          done 
        ) subs 
      ) fix_localization ; 
    ) fault_localization ; 
  end ; 
  debug "search: brute: %d subatom swaps\n" 
    !sub_counter;

  if !worklist = [] then begin
    debug "WARNING: no variants to consider (no fault localization?)\n" ; 
  end ; 

  let worklist = List.sort 
    (fun (m,w) (m',w') -> compare w' w) !worklist in 
  let howmany = List.length worklist in 
  let sofar = ref 1 in 
  List.iter (fun (thunk,w) ->
    debug "\tvariant %d/%d (weight %g)\n" !sofar howmany w ;
    let rep = thunk () in 
    incr sofar ;
    test_to_first_failure rep 
  ) worklist ; 

  debug "search: brute_force_1 ends\n" ; 
  [] 

(*************************************************************************
 *************************************************************************
                          Basic Genetic Algorithm
 *************************************************************************
 *************************************************************************)

(* Just get fault localization ids *)
let just_id inp = 
  List.map (fun (sid, prob) -> sid) (inp#get_fault_localization ())

let rec choose_from_weighted_list chosen_index lst = match lst with
  | [] -> failwith "localization error"  
  | (sid,prob) :: tl -> if chosen_index <= prob then sid
                  else choose_from_weighted_list (chosen_index -. prob) tl

(* tell whether we should mutate an individual *)
let maybe_mutate prob =
  if (Random.float 1.0) <= (!mutp *. prob) then true else false 

let choose_one_weighted lst = 
  assert(lst <> []); 
  let total_weight = List.fold_left (fun acc (sid,prob) ->
    acc +. prob) 0.0 lst in
  assert(total_weight > 0.0) ; 
  let wanted = Random.float total_weight in
  let rec walk lst sofar = 
    match lst with
    | [] -> failwith "choose_one_weighted" 
    | (sid,prob) :: rest -> 
      let here = sofar +. prob in 
      if here >= wanted then (sid,prob)
      else walk rest here 
  in
  walk lst 0.0 

(***********************************************************************
 * Weighted Micro-Mutation
 *
 * Here we pick delete, append or swap, and apply that atomic operator
 * with some probability to each element of the fault localization path.
 ***********************************************************************)

let mutate ?(test = false)  (variant : 'a Rep.representation) random = 
  let subatoms = variant#subatoms && !use_subatoms in 
  let result = variant#copy () in  
  let mut_ids = ref (variant#get_fault_localization ()) in 

  (* Splits search space for distributed algorithms *)
  if (!distributed || !network_dist) && !split_search then
    mut_ids := (List.filter (fun (x , prob) -> (x mod !num_comps) == !compnumber) !mut_ids)
  else ();
  let mut_ids =
    if !promut <= 0 then !mut_ids
    else uniq !mut_ids
  in
  let promut_list = 
    if !promut <= 0 then 
      []
    else begin
      let res = ref [] in
      for i = 1 to !promut do
        let sid, prob = choose_one_weighted mut_ids in 
        res := (sid) :: !res
      done ;
      !res
    end 
  in 
    List.iter (fun (x,prob) ->
      if (test || maybe_mutate prob || (List.mem x promut_list )) then 
	let rec atom_mutate max_op = (* stmt-level mutation *) 
          match Random.int max_op with 
          | 0 -> result#delete x
          | 1 -> 
	    let allowed = variant#append_sources x in 
	      if WeightSet.cardinal allowed > 0 then 
		let after = random allowed in
		  result#append x after
	      else atom_mutate 1
          | _ -> 
	    let allowed = variant#swap_sources x in 
	      if WeightSet.cardinal allowed > 0 then
		let swapwith = random allowed in 
		  result#swap x swapwith
	      else atom_mutate 2
	in 
      if subatoms && (Random.float 1.0 < !subatom_mutp) then begin
        (* sub-atom mutation *) 
        let x_subs = variant#get_subatoms x in 
        if x_subs = [] then atom_mutate 3
        else if ((Random.float 1.0) < !subatom_constp) then begin 
          let x_sub_idx = Random.int (List.length x_subs) in 
          result#replace_subatom_with_constant x x_sub_idx 
        end else begin 
          let allowed = variant#append_sources x in 
          let allowed = List.map fst (WeightSet.elements allowed) in 
          let allowed = random_order allowed in 
          let rec walk lst = match lst with
          | [] -> atom_mutate 3
          | src :: tl -> 
            let src_subs = variant#get_subatoms src in 
            if src_subs = [] then
              walk tl
            else begin
              let x_sub_idx = Random.int (List.length x_subs) in 
              let src_subs = random_order src_subs in 
              let src_sub = List.hd src_subs in 
              result#replace_subatom x x_sub_idx src_sub 
            end 
          in 
          walk allowed
        end 
      end else atom_mutate 3
  ) mut_ids ;
  (*(match Random.int 3 with
  | 0 -> result#delete (fault_location ())  
  | 1 -> result#append (fault_location ()) (fix_location ()) 
  | _ -> result#swap (fault_location ()) (fix_location ()) 
  ) ;*)
  result 

(* One point crossover *)
let do_cross ?(test = 0) 
        (variant1 : 'a Rep.representation) 
        (variant2 : 'a Rep.representation)
	: ('a representation) list =
	let c_one = variant1#copy () in
	let c_two = variant2#copy () in
	let mat_1 = just_id variant1 in
	let mat_2 = just_id variant2 in
	let _ = debug "Len: %d - %d\n", (List.length mat_1), (List.length mat_2) in
	let point = if test=0 then Random.int (List.length mat_1) else test in
	List.iter (fun p -> begin
				c_one#put (List.nth mat_1 p) (variant2#get (List.nth mat_2 p));
				c_two#put (List.nth mat_2 p) (variant1#get (List.nth mat_1 p));
				end ) 
			  (0--point) ;
    c_one#add_name_note (sprintf "x(:%d)" point) ;
    c_two#add_name_note (sprintf "x(%d:)" point) ;
	[c_one;c_two]
	
  
(***********************************************************************
 * Tournament Selection
 ***********************************************************************)
let tournament_k = ref 2 
let tournament_p = ref 1.00 

let tournament_selection (population : ('a representation * float) list) 
           (desired : int) 
           (* returns *) : 'a representation list = 
  let p = !tournament_p in 
  assert ( desired >= 0 ) ; 
  assert ( !tournament_k >= 1 ) ; 
  assert ( p >= 0.0 ) ; 
  assert ( p <= 1.0 ) ; 
  assert ( List.length population > 0 ) ; 
  let rec select_one () = 
    (* choose k individuals at random *) 
    let lst = random_order population in 
    (* sort them *) 
    let pool = first_nth lst !tournament_k in 
    let sorted = List.sort (fun (_,f) (_,f') -> compare f' f) pool in 
    let rec walk lst step = match lst with
    | [] -> select_one () 
    | (indiv,fit) :: rest -> 
        let taken = 
          if p >= 1.0 then true
          else begin 
            let required_prob = p *. ((1.0 -. p)**(step)) in 
            Random.float 1.0 <= required_prob 
          end 
        in
        if taken then (indiv) else walk rest (step +. 1.0)
    in
    walk sorted 0.0
  in 
  let answer = ref [] in 
  for i = 1 to desired do
    answer := (select_one ()) :: !answer
  done ;
  !answer

(* Selection -- currently we have only tournament selection implemented,
 * but if/when we add others, we choose between them here. *)  
let selection (population : ('a representation * float) list) 
           (desired : int) 
           (* returns *) : 'a representation list = 
  tournament_selection population desired

(***********************************************************************
 * Basic Genetic Algorithm Search Strategy
 *
 * This is parametric with respect to a number of choices (e.g.,
 * population size, selection method, fitness function, fault
 * localization, ...). 
 ***********************************************************************)

exception FoundIt of int

let genetic_algorithm ?(comp = 1) (original : 'a Rep.representation) incoming_pop = 
  debug "search: genetic algorithm begins\n" ;
  totgen := 0;

  (* Splitting up the search space for distributed algorithms *)
  if (!distributed || !network_dist) && !split_search then
    compnumber := comp
  else ();

  (* choose a stmt at random based on the fix localization strategy *) 
  let random atom_set = 
	if (*!uniform*) false then begin
	  let elts = List.map fst (WeightSet.elements atom_set) in
      let size = List.length elts in 
		List.nth elts (Random.int size) 
	end
	else (* Roulette selection! *)
	  begin
		let total = WeightSet.fold 
		  (fun (i,w) -> 
			fun total -> total +. w)
		  atom_set 0.0
		in
		let rand = Random.float total in
		  try
			ignore(WeightSet.fold
			  (fun (i,w) ->
				fun total ->
				  let total' = total +. w in
					if rand < total' then raise (FoundIt i)
					else total') atom_set 0.0);
			debug "No cumulative weight (max: %g) was less than rand: %g in Random.  Shouldn't happen." total rand;
			failwith "Weirdness in genetic_algorithm random"
		  with FoundIt ele -> ele;
	  end
  in  

  let pop = ref incoming_pop in (* our GP population *) 
  let firstsize = !popsize - (List.length incoming_pop) in
  if 0 > firstsize then begin
	debug "Too many variants in incoming population. Max is %d." (pred !popsize);
	exit(1)
  end;
  if firstsize > 0 then  
    (* include the original in the starting population *)
    pop := (original#copy ()) :: !pop ;
  for i = 2 to firstsize do
    (* initialize the population to a bunch of random mutants *) 
    pop := (mutate original random) :: !pop 
  done ;

  if !unit_test then begin
	debug "printing out original\n";
	original#output_source "original.c" ;
	let mone = List.nth !pop 1 in
	let mtwo = List.nth !pop 2 in
	debug "outputing original mutants mut_one and mut_two\n" ;
	mone#output_source "mut_one.c" ;
	mtwo#output_source "mut_two.c" ;
	debug "crossing them over\n" ;
	let mylist = do_cross mone mtwo ~test:5 in
	let cone = List.hd mylist in 
	let ctwo = List.hd (List.tl mylist) in
	debug "printing out children c_one c_two with crosspoint 5\n" ;
	cone#output_source "c_one.c" ;
	ctwo#output_source "c_two.c" ;
	debug "exiting...\n" ;
	assert(false) ;
  end ;

  let crossover (population : 'a Rep.representation list) = 
    let mating_list = random_order population in
    (* should we cross an individual? *)
    let maybe_cross () = if (Random.float 1.0) <= !crossp then true else false in
    let output = ref [] in
    let half = (List.length mating_list) / 2 in
    for it = 0 to (half - 1) do
      let parent1 = List.nth mating_list it in
      let parent2 = List.nth mating_list (half + it) in 
      if maybe_cross () then
        output := (do_cross parent1 parent2) @ !output 
      else 
        output := parent1 :: parent2 :: !output 
    done ;
    !output
  in

  (* Main GP Loop: *) 
	
  for gen = 1 to !generations do 
    if (not (!distributed || !network_dist)) then
      varnum := 0;
    debug "search: generation %d\n" gen ;      
    (* Step 1. Calculate fitness. *) 
	let incoming_population = calculate_fitness !pop in 
    (* Step 2: selection *) 
	let selected = selection incoming_population !popsize in
	(* Step 3: crossover *)
	let crossed = crossover selected in
    (* Step 4: mutation *)
    let mutated = List.map (fun one -> (mutate one random)) crossed in
    pop := mutated ;
    totgen := gen
  done ;
  debug "search: genetic algorithm ends\n" ;

  (* Returns a population, fitness pair*)
  (calculate_fitness !pop)
 