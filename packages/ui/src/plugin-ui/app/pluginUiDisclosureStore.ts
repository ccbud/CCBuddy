/** 手动固定与工具行裁决共用一个会话缓存，不能各自保留或淘汰。 */
export {
  getPluginUiManualPin,
  setPluginUiManualPin,
  getPluginUiDisclosureVersion,
  subscribePluginUiDisclosure,
  resetPluginUiInstancesForTest as resetPluginUiDisclosureForTest,
} from "./pluginUiInstanceStore.js";
