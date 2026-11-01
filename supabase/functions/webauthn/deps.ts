// Pinned server library (Deno resolves npm: specifiers). Tests swap this import for the installed package.
export {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "npm:@simplewebauthn/server@13.2.3";
