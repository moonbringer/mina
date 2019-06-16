open Core_kernel
open Async_kernel
open Pipe_lib
open Coda_base
open Coda_incremental

(** An extension to the transition frontier that provides a view onto the data
    other components can use. These are exposed through the broadcast pipes
    accessible by calling extension_pipes on a Transition_frontier.t. *)
module type Transition_frontier_extension_intf = sig
  (** Internal state of the extension. *)
  type t

  (** Data needed for setting up the extension*)
  type input

  type transition_frontier_diff

  (** The view type we're emitting. *)
  type view

  val create : input -> t

  (** The first view that is ever available. *)
  val initial_view : unit -> view

  (** Handle a transition frontier diff, and return the new version of the
        computed view, if it's updated. *)
  val handle_diff : t -> transition_frontier_diff -> view Option.t
end

module type Transition_frontier_diff0_intf = sig
  type breadcrumb

  type external_transition_validated

  type _ t =
    (* External transition of the node that is going on top of it *)
    | New_breadcrumb : breadcrumb -> external_transition_validated t
    (* External transition of the node that is going on top of it *)
    | Root_transitioned :
        { new_: breadcrumb (* The nodes to remove excluding the old root *)
        ; garbage: breadcrumb list }
        -> (* Remove the old Root *)
        external_transition_validated t
    (* TODO: Mutant is just the old best tip *)
    | Best_tip_changed : breadcrumb -> external_transition_validated t

  type 'a diff_mutant = 'a t

  module E : sig
    type t = E : 'output diff_mutant -> t
  end
end

(* TODO: Probably can remove *)
(* module type Root_history_read_only = sig
   type t

   type breadcrumb

   val lookup : t -> State_hash.t -> breadcrumb option

   val mem : t -> State_hash.t -> bool

   val is_empty : t -> bool
   end

   module type Root_history = sig
   include Root_history_read_only

   val create : int -> t

   val enqueue : t -> breadcrumb -> unit
   end *)

module type Broadcast_extension_intf = sig
  type t

  type view

  type breadcrumb

  type base_transition_frontier

  type diff

  val create : breadcrumb -> t Deferred.t

  val peek : t -> view

  val update : t -> base_transition_frontier -> diff list -> unit Deferred.t
end

module type Extension0 = sig
  type t

  type breadcrumb

  type base_transition_frontier

  type diff

  type view

  val create : breadcrumb -> t * view

  val handle_diffs : t -> base_transition_frontier -> diff list -> view option
end

module type Extensions0 = sig
  type breadcrumb

  type base_transition_frontier

  type diff

  module Snark_pool_refcount : sig
    module Work : sig
      type t = Transaction_snark.Statement.t list [@@deriving sexp, yojson]

      module Stable :
        sig
          module V1 : sig
            type t [@@deriving sexp, bin_io]

            include Hashable.S_binable with type t := t
          end
        end
        with type V1.t = t

      include Hashable.S with type t := t

      val gen : t Quickcheck.Generator.t
    end

    include
      Extension0
      with type view = int * int Work.Table.t
       and type breadcrumb := breadcrumb
       and type base_transition_frontier := base_transition_frontier
       and type diff := diff
  end

  module Best_tip_diff : sig
    type view =
      { new_user_commands: User_command.t list
      ; removed_user_commands: User_command.t list }

    include
      Extension0
      with type view := view
       and type breadcrumb := breadcrumb
       and type base_transition_frontier := base_transition_frontier
       and type diff := diff
  end
end

module type Transition_frontier_diff_intf = sig
  type breadcrumb

  type external_transition_validated

  type transaction_snark_scan_state

  (* TODO: Remove New_frontier. 
     Each transition frontier extension should be initialized by the input, the root breadcrumb *)
  type t =
    | New_breadcrumb of {previous: breadcrumb; added: breadcrumb}
        (** Triggered when a new breadcrumb is added without changing the root or best_tip *)
    | New_frontier of breadcrumb
        (** First breadcrumb to become the root of the frontier  *)
    | New_best_tip of
        { old_root: breadcrumb
        ; old_root_length: int
        ; new_root: breadcrumb
              (** Same as old root if the root doesn't change *)
        ; added_to_best_tip_path: breadcrumb Non_empty_list.t
              (* oldest first *)
        ; parent: breadcrumb
        ; new_best_tip_length: int
        ; removed_from_best_tip_path: breadcrumb list (* also oldest first *)
        ; garbage: breadcrumb list }
        (** Triggered when a new breadcrumb is added, causing a new best_tip *)
  [@@deriving sexp]

  module Hash : sig
    type t [@@deriving bin_io]

    val merge : t -> string -> t

    val empty : t

    val equal : t -> t -> bool

    val to_string : t -> string
  end

  module Mutant : sig
    module Root : sig
      (** Data representing the root of a transition frontier. 'root can either be an external_transition with hash or a state_hash  *)
      module Poly : sig
        type ('root, 'scan_state, 'pending_coinbase) t =
          { root: 'root
          ; scan_state: 'scan_state
          ; pending_coinbase: 'pending_coinbase }
      end

      type 'root t =
        ('root, transaction_snark_scan_state, Pending_coinbase.t) Poly.t
    end

    (** Diff.Mutant is a GADT that represents operations that affect the changes
        on the transition_frontier. The left-hand side of the GADT represents
        change that will occur to the transition_frontier. The right-hand side of
        the GADT represents which components are are effected by these changes
        and a certification that these components are handled appropriately.
        There are comments for each GADT that will discuss the operations that
        changes a `transition_frontier` and their corresponding side-effects.*)
    type _ t =
      | New_frontier :
          (external_transition_validated, State_hash.t) With_hash.t Root.t
          -> unit t
          (** New_frontier: When creating a new transition frontier, the
          transition_frontier will begin with a single breadcrumb that can be
          constructed mainly with a root external transition and a
          scan_state. There are no components in the frontier that affects
          the frontier. Therefore, the type of this diff is tagged as a unit. *)
      | Add_transition :
          (external_transition_validated, State_hash.t) With_hash.t
          -> Consensus.Data.Consensus_state.Value.t t
          (** Add_transition: Add_transition would simply add a transition to the
          frontier and is therefore the parameter for Add_transition. After
          adding the transition, we add the transition to its parent list of
          successors. To certify that we added it to the right parent. The
          consensus_state of the parent can accomplish this. *)
      | Remove_transitions :
          State_hash.t list
          -> Consensus.Data.Consensus_state.Value.t list t
          (** Remove_transitions: Remove_transitions is an operation that removes
          a set of transitions. We need to make sure that we are deleting the
          right transition and we use their consensus_state to accomplish
          this. Therefore the type of Remove_transitions is indexed by a list
          of consensus_state. *)
      | Update_root : State_hash.t Root.t -> State_hash.t Root.t t
          (** Update_root: Update root is an indication that the root state_hash
          and the root scan_state state. To verify that we update the right
          root, we can indicate the old root is being updated. Therefore, the
          type of Update_root is indexed by a state_hash and scan_state. *)

    type 'a diff_mutant = 'a t

    val key_to_yojson : 'output t -> Yojson.Safe.json

    val value_to_yojson : 'output t -> 'output -> Yojson.Safe.json

    val hash : Hash.t -> 'output t -> 'output -> Hash.t

    module E : sig
      type t = E : 'output diff_mutant -> t

      include Binable.S with type t := t

      type with_value =
        | With_value : 'output diff_mutant * 'output -> with_value
    end
  end

  module Best_tip_diff : sig
    type view =
      { new_user_commands: User_command.t list
      ; removed_user_commands: User_command.t list }

    include
      Transition_frontier_extension_intf
      with type transition_frontier_diff := t
       and type view := view
       and type input = unit
  end

  module Root_diff : sig
    type view =
      {user_commands: User_command.Stable.V1.t list; root_length: int option}
    [@@deriving bin_io]

    include
      Transition_frontier_extension_intf
      with type transition_frontier_diff := t
       and type view := view
       and type input = unit
  end

  module Persistence_diff :
    Transition_frontier_extension_intf
    with type transition_frontier_diff := t
     and type view = Mutant.E.with_value list
     and type input = unit
end

module type Transition_frontier_extensions_intf = sig
  type breadcrumb

  type external_transition_validated

  type transaction_snark_scan_state

  module Diff :
    Transition_frontier_diff_intf
    with type breadcrumb := breadcrumb
     and type external_transition_validated := external_transition_validated
     and type transaction_snark_scan_state := transaction_snark_scan_state

  module type Extension_intf =
    Transition_frontier_extension_intf
    with type transition_frontier_diff := Diff.t

  module Work : sig
    type t = Transaction_snark.Statement.t list [@@deriving sexp, yojson]

    module Stable :
      sig
        module V1 : sig
          type t [@@deriving sexp, bin_io]

          include Hashable.S_binable with type t := t
        end
      end
      with type V1.t = t

    include Hashable.S with type t := t

    val gen : t Quickcheck.Generator.t
  end

  module Root_history : sig
    type t

    val create : int -> t

    val lookup : t -> State_hash.t -> breadcrumb option

    val most_recent : t -> breadcrumb option

    val mem : t -> State_hash.t -> bool

    val is_empty : t -> bool

    val enqueue : t -> State_hash.t -> breadcrumb -> unit
  end

  module Transition_registry : sig
    type t

    val create : unit -> t

    val notify : t -> State_hash.t -> unit

    val register : t -> State_hash.t -> unit Deferred.t
  end

  module Snark_pool_refcount :
    Extension_intf with type view = int * int Work.Table.t

  type t =
    { root_history: Root_history.t
    ; snark_pool_refcount: Snark_pool_refcount.t
    ; transition_registry: Transition_registry.t
    ; best_tip_diff: Diff.Best_tip_diff.t
    ; root_diff: Diff.Root_diff.t
    ; persistence_diff: Diff.Persistence_diff.t
    ; new_transition: external_transition_validated New_transition.Var.t }
  [@@deriving fields]

  type writers =
    { snark_pool: Snark_pool_refcount.view Broadcast_pipe.Writer.t
    ; best_tip_diff: Diff.Best_tip_diff.view Broadcast_pipe.Writer.t
    ; root_diff: Diff.Root_diff.view Broadcast_pipe.Writer.t
    ; persistence_diff: Diff.Persistence_diff.view Broadcast_pipe.Writer.t }

  type readers =
    { snark_pool: Snark_pool_refcount.view Broadcast_pipe.Reader.t
    ; best_tip_diff: Diff.Best_tip_diff.view Broadcast_pipe.Reader.t
    ; root_diff: Diff.Root_diff.view Broadcast_pipe.Reader.t
    ; persistence_diff: Diff.Persistence_diff.view Broadcast_pipe.Reader.t }
  [@@deriving fields]

  val create : breadcrumb -> t

  val make_pipes : unit -> readers * writers

  val close_pipes : writers -> unit

  val handle_diff : t -> writers -> Diff.t -> unit Deferred.t
end

(** The type of the view onto the changes to the current best tip. This type
    needs to be here to avoid dependency cycles. *)
module type Transition_frontier_breadcrumb_intf = sig
  type t [@@deriving sexp, eq, compare, to_yojson]

  type display [@@deriving yojson]

  type staged_ledger

  type mostly_validated_external_transition

  type external_transition_validated

  type verifier

  val create :
       (external_transition_validated, State_hash.t) With_hash.t
    -> staged_ledger
    -> t

  (** The copied breadcrumb delegates to [Staged_ledger.copy], the other fields are already immutable *)
  val copy : t -> t

  val build :
       logger:Logger.t
    -> verifier:verifier
    -> trust_system:Trust_system.t
    -> parent:t
    -> transition:mostly_validated_external_transition
    -> sender:Envelope.Sender.t option
    -> ( t
       , [ `Invalid_staged_ledger_diff of Error.t
         | `Invalid_staged_ledger_hash of Error.t
         | `Fatal_error of exn ] )
       Result.t
       Deferred.t

  val transition_with_hash :
    t -> (external_transition_validated, State_hash.t) With_hash.t

  val staged_ledger : t -> staged_ledger

  val hash : t -> int

  val external_transition : t -> external_transition_validated

  val state_hash : t -> State_hash.t

  val parent_hash : t -> State_hash.t

  val consensus_state : t -> Consensus.Data.Consensus_state.Value.t

  val display : t -> display

  val name : t -> string

  val to_user_commands : t -> User_command.t list
end

module type Transition_frontier_base_intf = sig
  type mostly_validated_external_transition

  type external_transition_validated

  type transaction_snark_scan_state

  type staged_ledger

  type staged_ledger_diff

  type verifier

  type t [@@deriving eq]

  module Breadcrumb :
    Transition_frontier_breadcrumb_intf
    with type mostly_validated_external_transition :=
                mostly_validated_external_transition
     and type external_transition_validated := external_transition_validated
     and type staged_ledger := staged_ledger
     and type verifier := verifier

  val create :
       logger:Logger.t
    -> root_transition:( external_transition_validated
                       , State_hash.t )
                       With_hash.t
    -> root_snarked_ledger:Ledger.Db.t
    -> root_staged_ledger:staged_ledger
    -> consensus_local_state:Consensus.Data.Local_state.t
    -> t

  val find_exn : t -> State_hash.t -> Breadcrumb.t

  val logger : t -> Logger.t
end

(* TODO: merge this with base *)
module type Transition_frontier_base0_intf = sig
  include Transition_frontier_base_intf

  val max_length : int

  val consensus_local_state : t -> Consensus.Data.Local_state.t

  val all_breadcrumbs : t -> Breadcrumb.t list

  val root : t -> Breadcrumb.t

  val root_length : t -> int

  val best_tip : t -> Breadcrumb.t

  val path_map : t -> Breadcrumb.t -> f:(Breadcrumb.t -> 'a) -> 'a list

  val hash_path : t -> Breadcrumb.t -> State_hash.t list

  val find : t -> State_hash.t -> Breadcrumb.t option

  val successor_hashes : t -> State_hash.t -> State_hash.t list

  val successor_hashes_rec : t -> State_hash.t -> State_hash.t list

  val successors : t -> Breadcrumb.t -> Breadcrumb.t list

  val successors_rec : t -> Breadcrumb.t -> Breadcrumb.t list

  val common_ancestor : t -> Breadcrumb.t -> Breadcrumb.t -> State_hash.t

  val iter : t -> f:(Breadcrumb.t -> unit) -> unit

  val best_tip_path_length_exn : t -> int

  val shallow_copy_root_snarked_ledger : t -> Ledger.Mask.Attached.t

  val visualize_to_string : t -> string

  val visualize : filename:string -> t -> unit
end

module type Transition_frontier_intf = sig
  include Transition_frontier_base0_intf

  val create :
       logger:Logger.t
    -> root_transition:( external_transition_validated
                       , State_hash.t )
                       With_hash.t
    -> root_snarked_ledger:Ledger.Db.t
    -> root_staged_ledger:staged_ledger
    -> consensus_local_state:Consensus.Data.Local_state.t
    -> t Deferred.t

  module Transition_frontier_base :
    Transition_frontier_base0_intf
    with type mostly_validated_external_transition :=
                mostly_validated_external_transition
     and type external_transition_validated := external_transition_validated
     and type staged_ledger_diff := staged_ledger_diff
     and type staged_ledger := staged_ledger
     and type transaction_snark_scan_state := transaction_snark_scan_state
     and type verifier := verifier

  (** Adds a breadcrumb to the transition_frontier. It will first compute diffs
      corresponding to the add breadcrumb mutation. Then, these diffs will be
      fed into different extensions in the transition_frontier and the
      extensions will be updated accordingly. The updates that occur is based
      on the diff and the past version of the transition_frontier before the
      mutation occurs. Afterwards, the diffs are applied to the
      transition_frontier that will conduct the actual mutation on the
      transition_frontier. Finally, the updates on the extensions will be
      written into their respective broadcast pipes. It is important that all
      the updates on the transition_frontier are synchronous to prevent data
      races in the protocol. Thus, the writes must occur last on this function. *)
  val add_breadcrumb_exn : t -> Breadcrumb.t -> unit Deferred.t

  (** Like add_breadcrumb_exn except it doesn't throw if the parent hash is
      missing from the transition frontier *)
  val add_breadcrumb_if_present_exn : t -> Breadcrumb.t -> unit Deferred.t

  val find_in_root_history : t -> State_hash.t -> Breadcrumb.t option

  val root_history_path_map :
    t -> State_hash.t -> f:(Breadcrumb.t -> 'a) -> 'a Non_empty_list.t option

  val wait_for_transition : t -> State_hash.t -> unit Deferred.t

  module Diff :
    Transition_frontier_diff0_intf
    with type breadcrumb := Breadcrumb.t
     and type external_transition_validated := external_transition_validated

  module Extensions :
    Extensions0
    with type breadcrumb := Breadcrumb.t
     and type base_transition_frontier := Transition_frontier_base.t
     and type diff := Diff.E.t

  val snark_pool_refcount_pipe :
    t -> Extensions.Snark_pool_refcount.view Broadcast_pipe.Reader.t

  val best_tip_diff_pipe :
    t -> Extensions.Best_tip_diff.view Broadcast_pipe.Reader.t

  (* val persistence_diff_pipe :
    t -> Diff.Persistence_diff.view Broadcast_pipe.Reader.t *)

  val close : t -> unit

  module For_tests : sig
    val root_snarked_ledger : t -> Ledger.Db.t

    val root_history_mem : t -> State_hash.t -> bool

    val root_history_is_empty : t -> bool

    val apply_diff : t -> Diff.E.t -> unit
  end
end
