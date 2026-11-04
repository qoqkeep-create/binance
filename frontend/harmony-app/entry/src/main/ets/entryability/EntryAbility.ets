import { UIAbility, ConfigurationConstant, Configuration } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Runtime } from '../platform/Runtime';
import { WindowChrome } from '../platform/WindowChrome';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    const store = Runtime.create(this.context);
    const appearance = store.preferences.read('appearance', 'system');
    this.context.getApplicationContext().setColorMode(appearance === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : appearance === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
  }
  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    try { await WindowChrome.attach(stage.getMainWindowSync(), this.context); }
    catch (_) { console.error('Unable to configure app window'); }
    stage.loadContent('pages/Index');
  }
  onConfigurationUpdate(_configuration: Configuration): void {
    WindowChrome.refresh().catch(() => console.error('Unable to refresh system bars'));
  }
  onForeground(): void { if (Runtime.store.initialized) Runtime.store.start(); }
  onBackground(): void { Runtime.store.background(); }
  onDestroy(): void { Runtime.store.background(); WindowChrome.detach(); }
}
