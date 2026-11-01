import { UIAbility, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Runtime } from '../platform/Runtime';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    const store = Runtime.create(this.context);
    const appearance = store.preferences.read('appearance', 'system');
    this.context.getApplicationContext().setColorMode(appearance === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : appearance === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
  }
  onWindowStageCreate(stage: window.WindowStage): void { stage.loadContent('pages/Index'); }
  onForeground(): void { if (Runtime.store.initialized) Runtime.store.start(); }
  onBackground(): void { Runtime.store.background(); }
  onDestroy(): void { Runtime.store.background(); }
}
