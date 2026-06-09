import { create } from 'zustand';
import { Region } from '../helpers/regionsHelper';
import { SecureGetRegionsHelper } from '../helpers/APIHelper';

interface OciRegionsStore {
  ociRegions: Region[] | null;
  loading: boolean;
  error: string | null;
  fetchOciRegions: (token: string) => Promise<void>;
  clearOciRegions: () => void;
}

let activeFetch: Promise<void> | null = null;

type SecureGetRegion = {
  oci_region?: unknown;
  oci_region_name?: unknown;
  enabled?: unknown;
  capacity?: {
    limit?: unknown;
    active?: unknown;
    available?: unknown;
  };
};

const parseCapacity = (capacity: SecureGetRegion["capacity"]) => {
  if (!capacity || typeof capacity !== "object") return undefined;

  const limit = Number(capacity.limit);
  const active = Number(capacity.active);
  const available = Number(capacity.available);

  if (![limit, active, available].every((x) => Number.isSafeInteger(x) && x >= 0)) {
    return undefined;
  }

  return { limit, active, available };
};

const parseRegionsResponse = (data: unknown): Region[] | null => {
  if (!data || typeof data !== "object") return null;

  const regions = (data as { regions?: unknown }).regions;
  if (!Array.isArray(regions)) return null;

  const parsedRegions = regions.reduce<Region[]>((result, item) => {
    const region = item as SecureGetRegion;
    if (typeof region.oci_region !== "string" || typeof region.oci_region_name !== "string") {
      return result;
    }

    result.push({
      value: region.oci_region,
      name: region.oci_region_name,
      enabled: region.enabled !== false,
      capacity: parseCapacity(region.capacity),
    });

    return result;
  }, []);

  return parsedRegions.length ? parsedRegions : null;
};

export const fetchOciRegions = async (token: string, force = false) : Promise<void> => {
  const store = useOciRegionsStore.getState();
  if (activeFetch) return activeFetch;
  if (!force && (store.loading || store.ociRegions?.length)) return;
  
  activeFetch = store.fetchOciRegions(token);

  try {
    await activeFetch;
  } finally {
    activeFetch = null;
  }
};

export const useOciRegionsStore = create<OciRegionsStore>((set) => ({
  ociRegions: null,
  loading: false,
  error: null,

  fetchOciRegions: async (token: string) => {
    set({ loading: true, error: null });

    const result = await SecureGetRegionsHelper(token);

    if (result?.success) {
      const regions = parseRegionsResponse(result.data);
      if (!regions) {
        set({ error: 'Invalid regions response', loading: false });
        return;
      }

      set({ ociRegions: regions, loading: false });
    } else {
      set({ error: result?.error || 'Regions fetch failed', loading: false });
    }
  },

  clearOciRegions: () => {
    set({ ociRegions: null, error: null, loading: false });
  },
}));
