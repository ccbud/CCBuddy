import type { HistorySource } from "../contract.js";

export interface SourceStamp {
  path: string;
  size: bigint;
  mtimeNs: bigint;
  inode: bigint;
  device: bigint;
  fingerprint: string;
  createdAt: string;
  modifiedAt: string;
}

export interface Candidate {
  source: HistorySource;
  path: string;
  root: string;
  relativePath: string;
  id: string;
  stamp: SourceStamp;
}
