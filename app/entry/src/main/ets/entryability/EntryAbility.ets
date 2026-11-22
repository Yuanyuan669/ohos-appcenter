import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { Log } from '../common/Logger';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    Log.info('ability onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index').catch((e: Error) => {
      Log.error('loadContent failed: ' + e.message);
    });
  }

  onWindowStageDestroy(): void {
    Log.info('windowStage destroyed');
  }
}
