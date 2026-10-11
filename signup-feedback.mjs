export function signupFeedback(values,{requirementsLoaded=true,busy=false,minimumAge=21}={}) {
  const errors={};
  if (!values.name.trim()) errors.name='Enter your full name.';
  if (!/^[A-Za-z0-9_-]{3,24}$/.test(values.callsign)) errors.callsign='Use 3–24 letters, numbers, underscores or hyphens. No spaces.';
  if (!values.email.trim() || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(values.email.trim())) errors.email='Enter a valid email address, such as name@example.com.';
  if (!/^\+?1?[0-9]{10}$/.test(values.phone.replace(/[() .-]/g,''))) errors.phone='Enter a 10-digit US phone number (optional +1 country code).';
  if (values.password.length<12) errors.password='Password needs at least 12 characters ('+values.password.length+' of 12 entered).';
  if (!values.confirm) errors.confirm='Re-enter your password in Confirm password.';
  else if (values.password!==values.confirm) errors.confirm='Passwords do not match.';
  const missing=Object.values(errors);
  if (!values.age) missing.push('Check the confirmation that you are at least '+minimumAge+'.');
  if (!values.law) missing.push('Check the agreement to follow local, state and federal laws.');
  if (!values.accuracy) missing.push('Check the confirmation that your information is accurate.');
  if (!values.recognitionAck) missing.push('Check the digital recognition purchase acknowledgment.');
  if (!requirementsLoaded) missing.push('Membership requirements are still loading. If this continues, reload the page.');
  return {errors,missing,ready:missing.length===0&&!busy,title:busy?'Creating your account…':missing.length?'To enable Create account, complete the following:':'Everything is complete. You can create your account.'};
}
