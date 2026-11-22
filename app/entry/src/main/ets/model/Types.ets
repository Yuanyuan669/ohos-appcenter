/**
 * 与 store/index.json（schema v1）对齐的模型。
 * 字段定义见 docs/INDEX-SPEC.md。
 */
export interface MirrorEntry {
  id: string;
  name: string;
  template: string;
}

export interface VersionInfo {
  versionName: string;
  versionCode: number;
  sizeBytes: number;
  sha256: string;
  hap: string;
  publishedAt: string | null;
}

export interface LatestInfo extends VersionInfo {
  minAPIVersion: number;
  targetAPIVersion: number;
  releaseNotes: string;
  installMode: string;
}

export interface AppEntry {
  bundleName: string;
  name: string;
  summary: string;
  description: string;
  developer: string;
  license: string;
  source: string;
  category: string;
  tags: string[];
  deviceTypes: string[];
  latest: LatestInfo;
  versions: VersionInfo[];
  revoked: boolean;
}

export interface StoreIndex {
  schemaVersion: number;
  generatedAt: string;
  channel: string;
  minAppVersionCode: number;
  baseUrl: string;
  mirrors: MirrorEntry[];
  apps: AppEntry[];
}

/** 设备 -> PC agent 的安装请求（写入 sandbox ready/） */
export interface ReadyRequest {
  id: string;
  bundleName: string;
  versionCode: number;
  versionName: string;
  hap: string;
  sizeBytes: number;
  sha256: string;
  requestedAt: string;
}

/** PC agent -> 设备的结果（写入 sandbox done/） */
export interface InstallResult {
  id: string;
  bundleName: string;
  versionCode: number;
  versionName: string;
  sha256: string;
  status: string; // installed | failed
  message: string;
  installedAt: string | null;
}

export interface StoreSettings {
  indexUrl: string;
  pin: string;
}
