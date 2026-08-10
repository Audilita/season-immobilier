-- =====================================================================
-- SEASON IMMOBILIER — Suivi & pilotage des prospects
-- Complément au SQL déjà fourni : contraintes, stockage, RLS.
-- À exécuter dans Supabase > SQL Editor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Contrainte manquante sur les évaluations
--    (nécessaire pour l'upsert onConflict côté application)
-- ---------------------------------------------------------------------
alter table evaluations_suivi
  drop constraint if exists evaluations_suivi_unicite;

alter table evaluations_suivi
  add constraint evaluations_suivi_unicite
  unique (prospect_id, mois, evaluateur_id);

-- ---------------------------------------------------------------------
-- 2. Bucket de stockage des justificatifs
--    (ne PAS stocker les pièces jointes en base64 dans PostgreSQL)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('documents', 'documents', true)
on conflict (id) do nothing;

-- Lecture publique des justificatifs
drop policy if exists "documents_lecture" on storage.objects;
create policy "documents_lecture" on storage.objects
  for select using (bucket_id = 'documents');

-- Dépôt réservé aux utilisateurs authentifiés
drop policy if exists "documents_depot" on storage.objects;
create policy "documents_depot" on storage.objects
  for insert to authenticated with check (bucket_id = 'documents');

drop policy if exists "documents_maj" on storage.objects;
create policy "documents_maj" on storage.objects
  for update to authenticated using (bucket_id = 'documents');

-- ---------------------------------------------------------------------
-- 3. Fonction utilitaire : rôle de l'utilisateur connecté
--    ADAPTER : remplace 'utilisateurs' et 'auth_id' par tes noms réels.
--    Si ta table utilisateurs a pour clé primaire l'id auth Supabase,
--    remplace « where auth_id = auth.uid() » par « where id = auth.uid() ».
-- ---------------------------------------------------------------------
create or replace function public.role_utilisateur()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select lower(coalesce(role, ''))
  from utilisateurs
  where auth_id = auth.uid()
  limit 1;
$$;

create or replace function public.id_utilisateur()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from utilisateurs where auth_id = auth.uid() limit 1;
$$;

create or replace function public.est_direction()
returns boolean
language sql
stable
as $$
  select public.role_utilisateur() in ('gerante','gérante','admin','direction','assistante','assistante_commerciale');
$$;

-- ---------------------------------------------------------------------
-- 4. Cloisonnement RÉEL des prospects (côté serveur)
--    Sans ceci, le filtre par commercial reste contournable
--    depuis la console du navigateur.
-- ---------------------------------------------------------------------
alter table prospects enable row level security;

drop policy if exists "prospects_lecture" on prospects;
create policy "prospects_lecture" on prospects
  for select to authenticated
  using (
    public.est_direction()
    or commercial_id = public.id_utilisateur()
  );

drop policy if exists "prospects_ecriture" on prospects;
create policy "prospects_ecriture" on prospects
  for insert to authenticated
  with check (
    public.est_direction()
    or commercial_id = public.id_utilisateur()
  );

drop policy if exists "prospects_maj" on prospects;
create policy "prospects_maj" on prospects
  for update to authenticated
  using (
    public.est_direction()
    or commercial_id = public.id_utilisateur()
  );

drop policy if exists "prospects_suppression" on prospects;
create policy "prospects_suppression" on prospects
  for delete to authenticated
  using (public.est_direction());

-- ---------------------------------------------------------------------
-- 5. RLS sur les justifications
--    Le commercial dépose et modifie les siennes ;
--    seule la direction tranche.
-- ---------------------------------------------------------------------
alter table justifications_prospects enable row level security;

drop policy if exists "justif_lecture" on justifications_prospects;
create policy "justif_lecture" on justifications_prospects
  for select to authenticated
  using (
    public.est_direction()
    or commercial_id = public.id_utilisateur()
  );

drop policy if exists "justif_depot" on justifications_prospects;
create policy "justif_depot" on justifications_prospects
  for insert to authenticated
  with check (
    public.est_direction()
    or commercial_id = public.id_utilisateur()
  );

drop policy if exists "justif_maj" on justifications_prospects;
create policy "justif_maj" on justifications_prospects
  for update to authenticated
  using (
    public.est_direction()
    or commercial_id = public.id_utilisateur()
  );

-- ---------------------------------------------------------------------
-- 6. RLS sur les évaluations
--    Le commercial voit ses notes mais ne peut pas les écrire.
-- ---------------------------------------------------------------------
alter table evaluations_suivi enable row level security;

drop policy if exists "eval_lecture" on evaluations_suivi;
create policy "eval_lecture" on evaluations_suivi
  for select to authenticated
  using (
    public.est_direction()
    or commercial_id = public.id_utilisateur()
  );

drop policy if exists "eval_ecriture" on evaluations_suivi;
create policy "eval_ecriture" on evaluations_suivi
  for all to authenticated
  using (public.est_direction())
  with check (public.est_direction());

-- ---------------------------------------------------------------------
-- 7. RLS sur les relances internes
--    Le commercial voit les relances qui le concernent : c'est le point
--    qui rend la preuve opposable en entretien.
-- ---------------------------------------------------------------------
alter table relances_internes enable row level security;

drop policy if exists "relances_lecture" on relances_internes;
create policy "relances_lecture" on relances_internes
  for select to authenticated
  using (
    public.est_direction()
    or commercial_id = public.id_utilisateur()
  );

drop policy if exists "relances_ecriture" on relances_internes;
create policy "relances_ecriture" on relances_internes
  for insert to authenticated
  with check (public.est_direction());

-- ---------------------------------------------------------------------
-- 8. Vue de pilotage : synthèse mensuelle par commercial
--    Utilisable pour un export ou un tableau de bord direction.
-- ---------------------------------------------------------------------
create or replace view v_pilotage_commerciaux as
select
  u.id                                                as commercial_id,
  coalesce(u.prenom || ' ', '') || u.nom              as commercial,
  count(p.id)                                         as portefeuille,
  count(*) filter (
    where p.date_dernier_contact is null
       or p.date_dernier_contact < current_date - interval '15 days'
  )                                                   as prospects_en_retard,
  round(avg(current_date - p.date_dernier_contact), 1) as jours_moyens_sans_contact,
  count(distinct j.id)                                as justifications_deposees,
  count(distinct j.id) filter (
    where j.statut_validation = 'conteste'
  )                                                   as justifications_contestees,
  round(avg(
    (e.note_reactivite + e.note_qualite_suivi
     + e.note_pertinence + e.note_qualification) / 4.0
  ), 2)                                               as note_moyenne_suivi
from utilisateurs u
left join prospects p on p.commercial_id = u.id
left join justifications_prospects j on j.commercial_id = u.id
left join evaluations_suivi e on e.commercial_id = u.id
where lower(u.role) like 'commercial%'
group by u.id, u.prenom, u.nom;
