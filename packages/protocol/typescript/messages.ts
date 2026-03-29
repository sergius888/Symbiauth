// Generated TypeScript types from messages.schema.json
// DO NOT EDIT - This file is auto-generated

export enum ErrorCode {
  INVALID_TOKEN = "INVALID_TOKEN",
  SESSION_EXPIRED = "SESSION_EXPIRED", 
  CERTIFICATE_MISMATCH = "CERTIFICATE_MISMATCH",
  ALPN_MISMATCH = "ALPN_MISMATCH",
  RATE_LIMITED = "RATE_LIMITED",
  INTERNAL_ERROR = "INTERNAL_ERROR"
}

export enum EndSessionReason {
  USER_REQUESTED = "user-requested",
  PROXIMITY_LOST = "proximity-lost", 
  TIMEOUT = "timeout",
  ERROR = "error"
}

export interface PairingRequest {
  type: "pairingRequest";
  v: 1;
  /** Session ID from QR code */
  sid: string;
  /** One-time pairing token */
  tok: string;
  /** Human-readable device identifier */
  deviceId: string;
  /** SHA-256 fingerprint of client certificate */
  clientFp: string;
}

export interface PairingResponse {
  type: "pairingResponse";
  v: 1;
  /** Whether pairing was successful */
  success: boolean;
  /** Whether SAS verification is required */
  sasRequired: boolean;
  /** 6-digit SAS code for verification */
  sasCode?: string;
  /** Error message if pairing failed */
  error?: string;
}

export interface SasConfirm {
  type: "sasConfirm";
  v: 1;
  /** Whether user confirmed SAS match */
  confirmed: boolean;
}

export interface RequestCredential {
  type: "requestCredential";
  v: 1;
  /** Domain name requesting credentials */
  domain: string;
  /** Full URL of the login page */
  url?: string;
}

export interface Credential {
  type: "credential";
  v: 1;
  /** Username for the domain */
  username: string;
  /** Password for the domain */
  password: string;
}

export interface EndSession {
  type: "endSession";
  v: 1;
  /** Reason for ending the session */
  reason: EndSessionReason;
}

export interface Ping {
  type: "ping";
  v: 1;
  /** ISO 8601 timestamp */
  timestamp?: string;
}

export interface Pong {
  type: "pong";
  v: 1;
  /** ISO 8601 timestamp */
  timestamp?: string;
}

export interface ErrorMessage {
  type: "error";
  v: 1;
  /** Error code for programmatic handling */
  code: ErrorCode;
  /** Human-readable error message */
  message: string;
}

export type ArmadilloMessage = 
  | PairingRequest
  | PairingResponse
  | SasConfirm
  | RequestCredential
  | Credential
  | EndSession
  | Ping
  | Pong
  | ErrorMessage;

// Type guards for easier message handling
export function isPairingRequest(msg: ArmadilloMessage): msg is PairingRequest {
  return msg.type === "pairingRequest";
}

export function isPairingResponse(msg: ArmadilloMessage): msg is PairingResponse {
  return msg.type === "pairingResponse";
}

export function isError(msg: ArmadilloMessage): msg is ErrorMessage {
  return msg.type === "error";
}