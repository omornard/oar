open Types
open Interval 
open Simple_cbf_mb_h_ct
open Mysql
(*
TODO
2) Debug
3) Besteffort (need resource reverse order => is not it's true need some discussion with scheduling en performance evaluation specialists)
3.1) Suspend SCHEDULER_AVAILABLE_SUSPENDED_RESOURCE_TYPE
4) Message scheduler/job (same and more than perl scheduler) (* need to be optimize vectorize*)
5) Complete Tests infrastructure (automatic test / ruby) and add more tests...
6) Doc
7) Source cleanning (new directory ???)
*)

let besteffort_duration = Int64.of_int (5*60)

(*
>> 2**31 => 2147483648
>> 2**31 -1 => 2147483647
*)
let max_time = 2147483648L
let max_time_minus_one = 2147483647L
(* Constant duration time of a besteffort job *)
let besteffort_duration = 300L

let argv = if (Array.length(Sys.argv) > 2) then
      (Sys.argv.(1), (Int64.of_string Sys.argv.(2)))
    else
      ("default", Int64.of_float (Unix.time ()))

(* Determine global resource intervals and init_slots with or without resource availabilty (fied available_upto in resources table *)
let resources_init_slots_determination dbh now =
  let potential_resources = Iolib.get_resource_list dbh in
  let flag_wake_up_cmd = Conf.test_key("SCHEDULER_NODE_MANAGER_WAKE_UP_CMD") in 
    if flag_wake_up_cmd then
      let resources = List.filter (fun n -> ((n.state = Alive) || (n.state = Absent))) potential_resources in
        let resource_intervals = 
          if ((List.length resources) = 0) then
            begin
              Conf.log "none available ressources for scheduling any jobs"; exit 0
            end
          else
            ints2intervals (List.map (fun n -> n.resource_id) resources) 
          in
        let available_uptos = Iolib.get_available_uptos dbh in
        (* create corresponding job from available_up parameter of resource *) 
        let pseudo_job_av_upto a_upto =
                                    { jobid=0;
                                      moldable_id=0;
                                      time_b = if (a_upto<now) then now else a_upto;
                                     (* walltime = Int64.sub max_time_minus_one a_upto; *)
                                      walltime = if (a_upto<now) then (Int64.sub max_time_minus_one now) else (Int64.sub max_time_minus_one a_upto);
                                      types = [];
                                      constraints = [];
                                      hy_level_rqt = [];
                                      hy_nb_rqt = [];
                                      set_of_rs = (ints2intervals (Helpers.filter_map (fun n -> n.available_upto = a_upto) (fun n -> n.resource_id) resources));} 
          in
        let pseudo_jobs_resources_available_upto = Helpers.filter_map (fun n -> n < max_time_minus_one) (fun n -> pseudo_job_av_upto n) available_uptos in

        let slot_init = {time_s = now; time_e = max_time; set_of_res = resource_intervals} in
        let slots_init_available_upto_resources = split_slots_prev_scheduled_jobs [slot_init] pseudo_jobs_resources_available_upto in
          (resource_intervals,slots_init_available_upto_resources)
    else
      let resources = List.filter (fun n -> n.state = Alive) potential_resources in
      let resource_intervals = ints2intervals (List.map (fun n -> n.resource_id) resources) in
        (resource_intervals,[{time_s = now; time_e = max_time; set_of_res = resource_intervals}])

(*               *)
(* Main function *)
(*               *)
let _ = 
	try
		Conf.log "Starting";
    (* get hierarchy description from oar.conf and convert it in hierarchy levels *)
    Hierarchy.hierarchy_levels := Hierarchy.h_desc_to_h_levels Conf.get_hierarchy_info;

    let (queue,now) = argv in
		let conn = let r = Iolib.connect () in at_exit (fun () -> Iolib.disconnect r); r in
      let h_slots = Hashtbl.create 10 in
	    (* Hashtbl.add h_slots 0 [slot_init]; *)
      let  (resource_intervals,slots_init_available_upto_resources) = resources_init_slots_determination conn now in
        Hashtbl.add h_slots 0 slots_init_available_upto_resources;  

  		let (waiting_j_ids,h_waiting_jobs) = Iolib.get_job_list conn resource_intervals queue besteffort_duration in (* TODO 
      false -> alive_resource_intervals, must be also filter by type-default !!!  Are-you sure ??? *)
      Conf.log ("Job waiting ids"^ (Helpers.concatene_sep "," string_of_int waiting_j_ids));

      if (List.length waiting_j_ids) > 0 then
        begin

          (* get types attributs of wating jobs *)
          ignore (Iolib.get_job_types conn waiting_j_ids h_waiting_jobs);
          
          (* fill slots with prev scheduled jobs  *)
          let prev_scheduled_jobs = Iolib.get_scheduled_jobs conn in
          if not ( prev_scheduled_jobs = []) then
            let (h_prev_scheduled_jobs_types, prev_scheduled_job_ids_tmp) = Iolib.get_job_types_hash_ids conn prev_scheduled_jobs in
            let prev_scheduled_job_ids =
              if queue != "besteffort" then
                (* exclude besteffort jobs *)
                let besteffort_mem_remove job_id = 
                  let test_bt = List.mem_assoc "besteffort" ( try Hashtbl.find h_prev_scheduled_jobs_types job_id 
                                                          with Not_found -> failwith "Must no failed here: besteffort_mem").types in
                                                          if test_bt then () else  Hashtbl.remove  h_prev_scheduled_jobs_types job_id;
                                                          test_bt  
                  in  
                    List.filter (fun n -> not (besteffort_mem_remove n)) prev_scheduled_job_ids_tmp
 (*               Conf.log ("Previous Scheduled jobs no besteffort:\n"^  (Helpers.concatene_sep "\n\n" job_to_string prev_scheduled_jobs_no_bt) ); *)
              else
                prev_scheduled_job_ids_tmp
            in
             set_slots_with_prev_scheduled_jobs h_slots h_prev_scheduled_jobs_types prev_scheduled_job_ids;
          else ();

          (* get jobs' dependencies information *) 
          let h_jobs_dependencies = Iolib.get_current_jobs_dependencies conn in
          let h_req_jobs_status = Iolib.get_current_jobs_required_status conn in

          (* now compute an assignement for waiting jobs - MAKE A SCHEDULE *)
          let (assignement_jobs, noscheduled_jids) = schedule_id_jobs_ct_dep h_slots h_waiting_jobs h_jobs_dependencies h_req_jobs_status waiting_j_ids
          in
            Conf.log ((Printf.sprintf "Queue: %s, Now: %s" queue (ml642int now)));
(*          Conf.log ("slot_init:\n  " ^  slot_to_string slot_init); 
            Conf.log ("slots_with_scheduled_jobs:\n  " ^ (Helpers.concatene_sep "\n   " slot_to_string slots_with_scheduled_jobs));
  				  Conf.log ( "Resources found:\n   " ^ (Helpers.concatene_sep "\n   " resource_to_string resources) );        
	  		    Conf.log ( "Waiting jobs:\n"^  (Helpers.concatene_sep "\n   " job_waiting_to_string waiting_jobs) ); 
*)
(*
            Conf.log ("Previous Scheduled jobs:\n"^  (Helpers.concatene_sep "\n\n" job_to_string prev_scheduled_jobs) ); 
		        Conf.log ("Assigns:\n" ^  (Helpers.concatene_sep "\n\n" job_to_string assignement_jobs));
            Conf.log ("Ids of noscheduled jobs:" ^ (Helpers.concatene_sep "," (fun n-> Printf.sprintf "%d" n) noscheduled_jids) );
*)
            (* save assignements into db *)
            Iolib.save_assigns conn assignement_jobs;  
            Conf.log "Terminated";
 		        exit 0
          end
        else
	        Conf.log "No jobs to schedule, terminated";
          exit 0 
  with e -> 
    let error_message = Printexc.to_string e in 
      Conf.error error_message;;
