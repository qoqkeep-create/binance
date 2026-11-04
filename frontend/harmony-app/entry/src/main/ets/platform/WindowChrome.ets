import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

// The background fills the system bars; controls use the real device avoid areas.
export class WindowChrome {
  private static main: window.Window | null = null;
  private static context: common.UIAbilityContext | null = null;
  static async attach(main: window.Window, context: common.UIAbilityContext): Promise<void> {
    WindowChrome.main = main; WindowChrome.context = context;
    await main.setWindowLayoutFullScreen(true);
    WindowChrome.updateInsets();
    main.on('avoidAreaChange', () => WindowChrome.updateInsets());
    await WindowChrome.refresh();
  }
  private static updateInsets(): void {
    const main = WindowChrome.main; if (!main) return;
    const system = main.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const indicator = main.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    AppStorage.setOrCreate('window-top-inset', px2vp(system.topRect.height));
    AppStorage.setOrCreate('window-bottom-inset', px2vp(Math.max(system.bottomRect.height, indicator.bottomRect.height)));
  }
  static async refresh(): Promise<void> {
    const main = WindowChrome.main; const context = WindowChrome.context;
    if (!main || !context) return;
    const background = '#' + (context.resourceManager.getColorByNameSync('background') >>> 0).toString(16).padStart(8, '0');
    const content = '#' + (context.resourceManager.getColorByNameSync('text_primary') >>> 0).toString(16).padStart(8, '0');
    main.setWindowBackgroundColor(background);
    await main.setWindowSystemBarProperties({ statusBarColor: '#00000000', navigationBarColor: '#00000000', statusBarContentColor: content, navigationBarContentColor: content });
  }
  static detach(): void { WindowChrome.main = null; WindowChrome.context = null; }
}
