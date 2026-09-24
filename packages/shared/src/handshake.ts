export interface HelloMessage {
  type: "ccbuddy-hello";
  version: string;
  platform: string;
  arch: string;
  pid: number;
}

export interface HelloAckMessage {
  type: "ccbuddy-hello-ack";
  version: string;
  clientId: string;
}
