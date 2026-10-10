/** Production adapter: external Cloudflare deployment only. Not loaded by the private Sites demo.
 * Pass a Supabase client using its publishable key. Never pass a service-role client to browser code.
 * DB row-level rules are authoritative; this module never accepts another member's ID from a route.
 */
export function memberService(client, origin) {
  const parsed = new URL(origin);
  if (parsed.protocol !== 'https:' && parsed.hostname !== 'localhost') throw new Error('HTTPS origin required');
  const authRedirect = new URL('/account.html', parsed).href;
  const recoveryRedirect = new URL('/account.html', parsed).href;
  const unwrap = ({data,error}) => { if (error) throw error; return data; };
  async function user() {
    const {user} = unwrap(await client.auth.getUser());
    if (!user) throw new Error('Sign in required');
    return user;
  }
  return {
    async requirements() { return unwrap(await client.from('gac_requirements').select('*').single()); },
    async signUp({email,password,confirmPassword,profile,requirements}) {
      if (typeof password !== 'string' || password.length<12 || password!==confirmPassword) throw new Error('Use matching passwords of at least 12 characters');
      if (!profile.age_confirmed || !profile.law_agreed || !profile.accuracy_confirmed || !profile.recognition_acknowledged) throw new Error('Complete all required membership checks');
      // Password goes directly to Supabase Auth. Never copied into metadata, profiles, or local storage.
      return unwrap(await client.auth.signUp({email,password,options:{emailRedirectTo:authRedirect,data:{
        callsign:profile.callsign.trim().toUpperCase(),full_name:profile.full_name.trim(),phone:profile.phone.replace(/[() .-]/g,''),
        age_confirmed:true,law_agreed:true,accuracy_confirmed:true,recognition_acknowledged:true,
        minimum_age:requirements.minimum_age,requirements_version:requirements.version
      }}}));
    },
    async signIn(email,password) { return unwrap(await client.auth.signInWithPassword({email,password})); },
    async signOut() { unwrap(await client.auth.signOut({scope:'local'})); },
    async signOutEverywhere() { unwrap(await client.auth.signOut({scope:'global'})); },
    async requestPasswordReset(email) {
      unwrap(await client.auth.resetPasswordForEmail(email,{redirectTo:recoveryRedirect}));
      // Same UI response regardless of whether the account exists.
      return 'If an account exists for this email, a reset link will be sent.';
    },
    async updatePassword(password,confirmPassword) {
      if (password.length<12 || password!==confirmPassword) throw new Error('Use matching passwords of at least 12 characters');
      await user();return unwrap(await client.auth.updateUser({password}));
    },
    async myProfile() { const u=await user();return unwrap(await client.from('gac_profiles').select('*').eq('user_id',u.id).single()); },
    async myPurchases() { const u=await user();return unwrap(await client.from('gac_orders').select('*,gac_numbers(edition_number,callsign_at_purchase),gac_collections(callsign)').eq('user_id',u.id).order('paid_at',{ascending:false})); },
    async updateMyProfile(values) {
      const u=await user();
      const allowed=['callsign','full_name','contact_email','phone','preferred_ffl_name','preferred_ffl_address'];
      const clean=Object.fromEntries(allowed.filter(k=>Object.hasOwn(values,k)).map(k=>[k,values[k]]));
      return unwrap(await client.from('gac_profiles').update(clean).eq('user_id',u.id).select('*').single());
    },
    async changeLoginEmail(email) { await user();return unwrap(await client.auth.updateUser({email},{emailRedirectTo:authRedirect})); },
    async isOwner() { await user();return unwrap(await client.rpc('gac_is_owner')); },
    async wheelEntries(collectionId) { await user();return unwrap(await client.rpc('gac_wheel_entries',{p_collection_id:collectionId})); },
    async recognitionResult(collectionId) { await user();return unwrap(await client.rpc('gac_recognition_result',{p_collection_id:collectionId})); },
    async ownerMembers() { await user();if (!unwrap(await client.rpc('gac_is_owner'))) throw new Error('Owner access required');return unwrap(await client.from('gac_profiles').select('*').order('created_at',{ascending:false})); },
    async ownerRecognitions() { await user();if (!unwrap(await client.rpc('gac_is_owner'))) throw new Error('Owner access required');return unwrap(await client.from('gac_recognitions').select('*,gac_profiles!gac_recognitions_member_id_fkey(callsign,full_name,contact_email,phone),gac_collections(callsign,is_test)').order('selected_at',{ascending:false})); },
    async setMemberStatus(memberId,status) { await user();return unwrap(await client.rpc('gac_set_member_status',{p_user_id:memberId,p_status:status})); }
  };
}
