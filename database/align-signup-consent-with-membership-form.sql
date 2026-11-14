-- Keep account enrollment aligned with the membership form.
-- Purchase acknowledgment belongs at checkout; do not require or record it during signup.
CREATE OR REPLACE FUNCTION gac_private.create_member_on_signup()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 r public.gac_requirements;
 m jsonb := coalesce(new.raw_user_meta_data,'{}');
 c text;
begin
 select * into strict r from public.gac_requirements where singleton;
 c := upper(trim(coalesce(m->>'callsign','')));
 if c !~ '^[A-Z0-9_-]{3,24}$' or length(trim(coalesce(m->>'full_name','')))=0
   or coalesce(m->>'phone','') !~ '^\+?1?[0-9]{10}$'
   or (m->>'age_confirmed') is distinct from 'true'
   or (m->>'law_agreed') is distinct from 'true'
   or (m->>'accuracy_confirmed') is distinct from 'true'
   or coalesce(m->>'requirements_version','')<>r.version::text
   or coalesce(m->>'minimum_age','')<>r.minimum_age::text
 then
   raise exception 'Required membership information or agreement is missing or outdated';
 end if;
 insert into public.gac_profiles(user_id,callsign,full_name,contact_email,phone)
 values(new.id,c,trim(m->>'full_name'),new.email,m->>'phone');
 insert into public.gac_callsign_history(callsign,user_id) values(c,new.id);
 insert into public.gac_consent_history(user_id,kind,requirements_version,wording,choices)
 values(new.id,'enrollment',r.version,jsonb_build_object('minimum_age',r.minimum_age,'law_statement',r.law_statement),
 jsonb_build_object('age_confirmed',true,'law_agreed',true,'accuracy_confirmed',true,'sms_opt_in',false,'marketing_opt_in',false));
 return new;
end $function$;
