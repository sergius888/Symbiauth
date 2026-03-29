// Armadillo Chrome Extension Messaging Utilities
// Type-safe message handling between extension components

export interface ArmadilloMessage {
  type: string;
  requestId?: string;
  timestamp?: string;
}

export interface PairingRequest extends ArmadilloMessage {
  type: 'pairingRequest';
  sid: string;
  tok: string;
  deviceId: string;
  clientFp: string;
}

export interface PairingResponse extends ArmadilloMessage {
  type: 'pairingResponse';
  success: boolean;
  sasRequired: boolean;
  sasCode?: string;
  error?: string;
}

export interface RequestCredential extends ArmadilloMessage {
  type: 'requestCredential';
  domain: string;
  url?: string;
}

export interface Credential extends ArmadilloMessage {
  type: 'credential';
  username: string;
  password: string;
}

export interface EndSession extends ArmadilloMessage {
  type: 'endSession';
  reason: 'user-requested' | 'proximity-lost' | 'timeout' | 'error';
}

export interface Ping extends ArmadilloMessage {
  type: 'ping';
}

export interface Pong extends ArmadilloMessage {
  type: 'pong';
}

export interface ErrorMessage extends ArmadilloMessage {
  type: 'error';
  code: string;
  message: string;
}

export type ArmadilloMessageType = 
  | PairingRequest
  | PairingResponse
  | RequestCredential
  | Credential
  | EndSession
  | Ping
  | Pong
  | ErrorMessage;

export class MessageValidator {
  static validateMessage(message: any): message is ArmadilloMessageType {
    if (!message || typeof message !== 'object') {
      return false;
    }

    if (!message.type || typeof message.type !== 'string') {
      return false;
    }

    // Basic validation for each message type
    switch (message.type) {
      case 'pairingRequest':
        return !!(message.sid && message.tok && message.deviceId && message.clientFp);
      
      case 'pairingResponse':
        return typeof message.success === 'boolean' && typeof message.sasRequired === 'boolean';
      
      case 'requestCredential':
        return !!message.domain;
      
      case 'credential':
        return !!(message.username && message.password);
      
      case 'endSession':
        return !!message.reason;
      
      case 'ping':
      case 'pong':
        return true;
      
      case 'error':
        return !!(message.code && message.message);
      
      default:
        return false;
    }
  }

  static createErrorMessage(code: string, message: string): ErrorMessage {
    return {
      type: 'error',
      code,
      message,
      timestamp: new Date().toISOString()
    };
  }
}

export class MessageHandler {
  private handlers = new Map<string, (message: ArmadilloMessageType) => void>();

  on<T extends ArmadilloMessageType>(
    type: T['type'], 
    handler: (message: T) => void
  ): void {
    this.handlers.set(type, handler as (message: ArmadilloMessageType) => void);
  }

  handle(message: any): boolean {
    if (!MessageValidator.validateMessage(message)) {
      console.error('Invalid message received:', message);
      return false;
    }

    const handler = this.handlers.get(message.type);
    if (handler) {
      handler(message);
      return true;
    }

    console.warn('No handler for message type:', message.type);
    return false;
  }

  off(type: string): void {
    this.handlers.delete(type);
  }
}