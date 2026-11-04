import { common } from '@kit.AbilityKit';
import { AppStore } from '../../entry/src/main/ets/core/AppStore';
import { Session } from '../../entry/src/main/ets/core/Session';
import { CapitalWorkflow, BulkClose } from '../../entry/src/main/ets/core/Workflows';
import { Commands } from '../../entry/src/main/ets/core/Commands';
import { Realtime } from '../../entry/src/main/ets/core/Realtime';
import { PreviewTransport, PreviewVault, PreviewPreferences, PreviewClock, PreviewSocket } from './PreviewPorts';

/** Copied over Runtime ONLY in the ignored preview project; no native network/storage ports. */
export class Runtime {
  private static instance: AppStore | null = null;
  static get store(): AppStore {
    if (!Runtime.instance) throw new Error('UI preview is not initialized');
    return Runtime.instance;
  }
  static create(_context: common.UIAbilityContext): AppStore {
    if (Runtime.instance) return Runtime.instance;
    const vault = new PreviewVault(); const clock = new PreviewClock();
    const session = new Session(new PreviewTransport(), vault); const commands = new Commands(session, vault, clock);
    Runtime.instance = new AppStore(session, commands, new Realtime(session, new PreviewSocket(), clock), new PreviewPreferences(), clock, new CapitalWorkflow(session, vault), new BulkClose(session, commands, vault, clock));
    return Runtime.instance;
  }
}
