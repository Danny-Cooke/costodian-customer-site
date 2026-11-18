// Where the preview keeps what a visitor types: this browser tab only. Nothing
// is sent anywhere. If the browser refuses storage, it falls back to memory,
// which lasts for the one page.

export function memoryStorage() {
  const items = new Map();
  return {
    getItem: (key) => (items.has(key) ? items.get(key) : null),
    setItem: (key, value) => {
      items.set(key, String(value));
    },
    removeItem: (key) => {
      items.delete(key);
    },
  };
}

export function browserStorage(probeKey) {
  try {
    const storage = window.sessionStorage;
    storage.setItem(probeKey, "");
    storage.removeItem(probeKey);
    return storage;
  } catch {
    return memoryStorage();
  }
}

export function createStore(key, storage) {
  return {
    load() {
      try {
        const state = JSON.parse(storage.getItem(key));
        return state !== null && typeof state === "object" && !Array.isArray(state) ? state : {};
      } catch {
        return {};
      }
    },
    save(state) {
      try {
        storage.setItem(key, JSON.stringify(state));
        return true;
      } catch {
        return false;
      }
    },
    clear() {
      try {
        storage.removeItem(key);
      } catch {
        // Nothing to clear if storage is unavailable.
      }
    },
  };
}
