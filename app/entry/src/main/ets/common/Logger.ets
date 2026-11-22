import hilog from '@ohos.hilog';

const DOMAIN = 0x0001;

export class Log {
  static info(msg: string): void {
    hilog.info(DOMAIN, 'AppCenter', '%{public}s', msg);
  }

  static warn(msg: string): void {
    hilog.warn(DOMAIN, 'AppCenter', '%{public}s', msg);
  }

  static error(msg: string): void {
    hilog.error(DOMAIN, 'AppCenter', '%{public}s', msg);
  }
}
