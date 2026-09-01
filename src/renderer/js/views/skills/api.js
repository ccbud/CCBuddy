/* One narrow Skills Hub facade over the shared Tauri bridge. */
import { api } from '../../core/bridge.js';

export const skillsApi = {
  snapshot: async () => {
    const [skills, status, tools] = await Promise.all([
      api.skillsList(), api.skillsStatus(), api.skillsTools(),
    ]);
    return { skills, status, tools };
  },
  list: () => api.skillsList(),
  status: () => api.skillsStatus(),
  detail: (id) => api.skillsDetail(id),
  readFile: (id, filePath) => api.skillsReadFile(id, filePath),
  tools: () => api.skillsTools(),
  pickLocal: () => api.skillsPickLocal(),
  scanLocal: (path) => api.skillsScanLocal(path),
  importLocal: (path) => api.skillsImportLocal(path),
  importGit: (url) => api.skillsImportGit(url),
  remove: (id) => api.skillsDelete(id),
  refresh: (id) => api.skillsRefresh(id == null ? null : id),
  update: (id) => api.skillsUpdate(id),
  syncConflicts: (id, targetKeys) => api.skillsSyncConflicts(id, targetKeys),
  sync: (id, targetKeys, mode, authorizing = []) => api.skillsSync(id, targetKeys, mode, authorizing),
  unsync: (id, targetKeys) => api.skillsUnsync(id, targetKeys),
  setTags: (id, tags) => api.skillsSetTags(id, tags),
  openRoot: () => api.skillsOpenRoot(),
};
