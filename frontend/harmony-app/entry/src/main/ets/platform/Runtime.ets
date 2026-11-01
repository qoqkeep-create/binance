import { common } from '@kit.AbilityKit';
import { AppStore } from '../core/AppStore';
import { Session } from '../core/Session';
import { CapitalWorkflow, BulkClose } from '../core/Workflows';
import { Commands } from '../core/Commands';
import { Realtime } from '../core/Realtime';
import { NativeClock, NativePreferences, NativeSocket, NativeTransport, AssetVault } from './NativePorts';

export class Runtime {
  private static instance: AppStore | null = null;
  static get store(): AppStore {
    if (!Runtime.instance) throw new Error('客户端尚未初始化');
    return Runtime.instance;
  }
  static create(context: common.UIAbilityContext): AppStore {
    if (Runtime.instance) return Runtime.instance;
    const transport = new NativeTransport(); const vault = new AssetVault(); const clock = new NativeClock();
    const session = new Session(transport, vault); const commands = new Commands(session, vault, clock);
    Runtime.instance = new AppStore(session, commands, new Realtime(session, new NativeSocket(), clock), new NativePreferences(context), clock, new CapitalWorkflow(session, vault), new BulkClose(session, commands, vault, clock));
    return Runtime.instance;
  }
}
