// What is done and what is left in a firm's set-up, from the saved state.

export function setupStatus(state, agreementVersion) {
  const company = Boolean(state?.company?.savedAt);
  const agreement = Boolean(state?.agreement?.acceptedAt) && state.agreement.version === agreementVersion;
  const details = isSignedUp(state);
  return { details, company, agreement, ready: details && company && agreement };
}

export function isSignedUp(state) {
  return Boolean(state?.signup?.completedAt);
}
