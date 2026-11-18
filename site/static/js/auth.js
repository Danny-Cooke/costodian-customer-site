// Sign-in, through the sign-in service's own API. The password goes straight
// from this page to that service over TLS and is never kept: only the tokens it
// returns are held, in this browser tab, until sign out.

import { browserStorage } from "./store.js";

const SERVICE = "AWSCognitoIdentityProviderService";
const CONTENT_TYPE = "application/x-amz-json-1.1";
const PASSWORD_FLOW = "USER_PASSWORD_AUTH";
const REFRESH_FLOW = "REFRESH_TOKEN_AUTH";
const NEW_PASSWORD_CHALLENGE = "NEW_PASSWORD_REQUIRED";

// What the service calls each failure, and the message key shown for it.
const MESSAGE_KEYS = {
  UsernameExistsException: "auth_exists",
  NotAuthorizedException: "auth_wrong",
  UserNotFoundException: "auth_wrong",
  CodeMismatchException: "auth_code_wrong",
  ExpiredCodeException: "auth_code_expired",
  InvalidPasswordException: "auth_password_weak",
  LimitExceededException: "auth_too_many",
  TooManyRequestsException: "auth_too_many",
  TooManyFailedAttemptsException: "auth_too_many",
};
const NOT_CONFIRMED = "UserNotConfirmedException";
const FALLBACK_KEY = "auth_failed";

export class AuthError extends Error {
  constructor(type, messageKey) {
    super(type);
    this.type = type;
    this.messageKey = messageKey;
    this.notConfirmed = type === NOT_CONFIRMED;
  }
}

export function createAuth(data, { fetcher = globalThis.fetch, storage, clock = () => Date.now() } = {}) {
  const settings = data.auth;
  const held = storage ?? browserStorage(`${settings.sessionKey}-probe`);

  async function call(action, body) {
    let response;
    try {
      response = await fetcher(settings.endpoint, {
        method: "POST",
        headers: { "Content-Type": CONTENT_TYPE, "X-Amz-Target": `${SERVICE}.${action}` },
        body: JSON.stringify(body),
      });
    } catch {
      throw new AuthError("NetworkError", FALLBACK_KEY);
    }
    const answer = await response.json().catch(() => ({}));
    if (!response.ok) {
      const type = String(answer.__type ?? "").split("#").pop();
      throw new AuthError(type, MESSAGE_KEYS[type] ?? FALLBACK_KEY);
    }
    return answer;
  }

  function session() {
    try {
      const saved = JSON.parse(held.getItem(settings.sessionKey));
      return saved && typeof saved.idToken === "string" ? saved : null;
    } catch {
      return null;
    }
  }

  function keep(result, refreshToken) {
    held.setItem(
      settings.sessionKey,
      JSON.stringify({
        idToken: result.IdToken,
        refreshToken: result.RefreshToken ?? refreshToken,
        expiresAt: clock() + result.ExpiresIn * 1000,
      }),
    );
  }

  function forget() {
    held.removeItem(settings.sessionKey);
  }

  return {
    enabled: settings.enabled,
    signedIn: () => session() !== null,

    signUp: (email, password, name) =>
      call("SignUp", {
        ClientId: settings.clientId,
        Username: email,
        Password: password,
        UserAttributes: [
          { Name: "email", Value: email },
          { Name: "name", Value: name },
        ],
      }),

    confirm: (email, code) => call("ConfirmSignUp", { ClientId: settings.clientId, Username: email, ConfirmationCode: code }),

    resend: (email) => call("ResendConfirmationCode", { ClientId: settings.clientId, Username: email }),

    async signIn(email, password) {
      const answer = await call("InitiateAuth", {
        ClientId: settings.clientId,
        AuthFlow: PASSWORD_FLOW,
        AuthParameters: { USERNAME: email, PASSWORD: password },
      });
      if (answer.ChallengeName === NEW_PASSWORD_CHALLENGE) {
        // An invited person signing in with the temporary password: they choose
        // their own before anything else. The caller finishes with newPassword().
        const error = new AuthError(NEW_PASSWORD_CHALLENGE, "auth_new_password");
        error.newPasswordNeeded = true;
        error.session = answer.Session;
        throw error;
      }
      if (!answer.AuthenticationResult) throw new AuthError("ChallengeNotSupported", FALLBACK_KEY);
      keep(answer.AuthenticationResult);
    },

    async newPassword(email, password, session) {
      const answer = await call("RespondToAuthChallenge", {
        ClientId: settings.clientId,
        ChallengeName: NEW_PASSWORD_CHALLENGE,
        Session: session,
        ChallengeResponses: { USERNAME: email, NEW_PASSWORD: password },
      });
      if (!answer.AuthenticationResult) throw new AuthError("ChallengeNotSupported", FALLBACK_KEY);
      keep(answer.AuthenticationResult);
    },

    forgot: (email) => call("ForgotPassword", { ClientId: settings.clientId, Username: email }),

    reset: (email, code, password) =>
      call("ConfirmForgotPassword", { ClientId: settings.clientId, Username: email, ConfirmationCode: code, Password: password }),

    // The token to send with an API request, renewed first if it is about to
    // run out. Null means the person has to sign in again.
    async token() {
      const current = session();
      if (!current) return null;
      if (current.expiresAt - clock() > settings.refreshMarginSeconds * 1000) return current.idToken;
      try {
        const answer = await call("InitiateAuth", {
          ClientId: settings.clientId,
          AuthFlow: REFRESH_FLOW,
          AuthParameters: { REFRESH_TOKEN: current.refreshToken },
        });
        keep(answer.AuthenticationResult, current.refreshToken);
        return session().idToken;
      } catch {
        forget();
        return null;
      }
    },

    async signOut() {
      const current = session();
      forget();
      if (!current?.refreshToken) return;
      // Ends the session at the service too. Signing out here does not wait on it.
      await call("RevokeToken", { ClientId: settings.clientId, Token: current.refreshToken }).catch(() => {});
    },
  };
}
