(* General imports to work with TemplateMonad *)
From MetaCoq.Template Require Import All.
From MetaCoq.Utils Require Import bytestring.
Require Import List.
Import MCMonadNotation ListNotations.
Open Scope bs.

Fixpoint decompose_lam_assum (Γ : context) (t : term) : context * term :=
  match t with
  | tLambda n A B => decompose_lam_assum (Γ ,, vass n A) B
  | tLetIn na b bty b' => decompose_prod_assum (Γ ,, vdef na b bty) b'
  | _ => (Γ, t)
  end.

Definition autoinduct (p : program) : term :=
  let (Σ, t) := p in
  (* decompose into head and arguments *)
  let (hd, args) := decompose_app t in
  let (n, hd') := match hd with
             | tConst kn _ => match lookup_constant Σ kn with
                             | Some b => match b.(cst_body) with
                                        | Some b => let (lambdas, rhd) := decompose_lam_assum [] b in
                                                   (List.length lambdas, rhd)
                                        | None => (0, tVar "error: constant has no body")
                                        end
                             | None => (0, tVar "error: constant not declared")
                             end
             | x => (0, x)
             end in
  match hd' with
  | tFix mfix idx =>
      match nth_error mfix idx with
      | Some f => match nth_error args (n + f.(rarg)) with
                 | Some x => x
                 | None => tVar "not enough arguments for induction"
                 end
      | None => tVar "ill-typed fixpoint"
      end
  | _ => tVar "passed term does not unfold to a fixpoint"
  end.

Tactic Notation "autoinduct" "on" constr(f) :=
  run_template_program (t <- tmQuoteRec f ;;
                        a <- tmEval lazy (autoinduct t) ;;
                        tmUnquote a)
    (fun x => let t := eval unfold my_projT2 in (my_projT2 x) in
             induction t).


Unset Guard Checking.
Section Autoinduct2.

  Definition eq_const (c1 c2: term) : bool :=
  match c1, c2 with
  | tConst kn1 _, tConst kn2 _ => kn1 == kn2
  | _, _ => false
  end.

  Fixpoint drop_quantification (t : term) : term :=
    match t with
    | tProd _ _ b => drop_quantification b
    | _ => t
    end.

  (* Checks if the applied term of any tApp in args is f *)
  Fixpoint find_cnst_in_args (f : term) (args : list term): term :=
    match args with
    | nil => tVar "error: passed term does not appear in the goal"
    | cons a args => match a with
                 | tApp hd a_args => if eq_const hd f
                                    then a
                                    else find_cnst_in_args f args
                 | _ => find_cnst_in_args f args
                 end
    end.

  (* From a list of terms returns all the tApp nodes, including the ones appearing as arguments *)
  Fixpoint split_apps (ts : list term) : list term :=
    match ts with
    | nil => nil term
    | (tApp hd args) :: ts' => (tApp hd args) :: (split_apps args) ++ (split_apps ts')
    | _ :: ts' => split_apps ts'
    end.

  (* Finds if f appears applied in ctx *)
  Definition find_app (ctx f: program) : term :=
    let (_, f) := f in
    let (Σ, t) := ctx in
    let goal := drop_quantification t in
    match goal with
    | tApp hd args => if eq_const hd f
                     then goal
                     else find_cnst_in_args f (split_apps (map drop_quantification args))
    | _ => tVar "error: the goal does not have an application"
    end.

End Autoinduct2.

Tactic Notation "autoinduct2" "on" constr(f) :=
  match goal with
  | [ |- ?G ] => run_template_program (goal <- tmQuoteRec G;;
                                     fp <- tmQuoteRec f;;
                                     t <- match fp.2 with
                                         | tApp _ _=> tmReturn fp (* f comes with args *)
                                         | _ => app_f <- tmEval lazy (find_app goal fp);; (* f is just the name of the fixpoint *)
                                               tmReturn (goal.1,app_f)
                                         end;;
                                     a <- tmEval lazy (autoinduct t);;
                                     tmUnquote a
                 )
                 (fun x =>
                    let t := eval unfold my_projT2 in (my_projT2 x) in
                      induction t
                 )
  end.

Section Autoinduct3.

  (* Looks in the goal applications of fixpoints *)
  Definition find_fixpoints (ctx : program) : list term :=
    let (Σ, t) := ctx in
    let goal := drop_quantification t in
    let fixpoint_candidates := match goal with
                               | tApp hd args => (goal :: (split_apps (map drop_quantification args)))
                               | _ => [tVar "error: the goal does not have an application"]
                               end in

    let fixpoints := filter
                       (fun t=> match t with
                             | tApp (tConst kn _) _ => (match lookup_constant Σ kn with
                                                       | Some b => true
                                                       | _ => false
                                                       end)
                             | _ => false end)
                       fixpoint_candidates
    in
    fixpoints.


End Autoinduct3.

Tactic Notation "autoinduct" :=
  match goal with
  | [ |- ?G ] => run_template_program (goal <- tmQuoteRec G;;
                                     fixes <- tmEval lazy (find_fixpoints goal);;
                                     pfixes <- tmEval lazy (map (fun t=> (goal.1,t)) fixes);;
                                     autoinducts <- tmEval lazy (map autoinduct pfixes);;
                                     (* filtering candidates which are function calls *)
                                     autoinducts <- tmEval lazy (filter (fun t=> match t with | tApp _ _ => false | _ => true end) autoinducts);;
                                     (* todo filter errors in autoinducts *)
                                     let appf := match head autoinducts with
                                                 | None => tVar "error: no candidate fixpoints to make induction"
                                                 | Some x => x
                                                 end in
                                     a <- tmEval lazy appf;;
                                     tmUnquote a

                 )
                 (fun x =>
                    let t := eval unfold my_projT2 in (my_projT2 x) in
                      induction t
                 )
  end.

Lemma test : forall n, n + 0 = n.
Proof.
  intros.
  autoinduct on (plus n 0).
  all: cbn; congruence.
Qed.

Lemma map_length : forall [A B : Type] (f : A -> B) (l : list A), #|map f l| = #|l|.
Proof.
  intros. autoinduct on (map f l); simpl; auto.
Qed.

(* works without the args *)
Lemma test2 : forall n, n + 0 = n.
Proof.
  intros.
  autoinduct2 on plus.
  all: cbn; congruence.
Qed.

(* still works with (plus n 0) *)
Lemma test2_ : forall n, n + 0 = n.
Proof.
  intros.
  autoinduct2 on (plus n 0).
  all: cbn; congruence.
Qed.

(* works without the args *)
Lemma map_length2 : forall [A B : Type] (f : A -> B) (l : list A), #|map f l| = #|l|.
Proof.
  intros. autoinduct2 on map; simpl; auto.
Qed.

(* still works with (map f l) *)
Lemma map_length2_ : forall [A B : Type] (f : A -> B) (l : list A), #|map f l| = #|l|.
Proof.
  intros. autoinduct2 on (map f l) ; simpl; auto.
Qed.

Lemma test3 : forall n, n + 0 = n.
Proof.
  intros.
  autoinduct.
  all: cbn; congruence.
Qed.

Lemma map_length3 : forall [A B : Type] (f : A -> B) (l : list A), #|map f l| = #|l|.
Proof.
  intros. autoinduct; simpl; auto.
Qed.

