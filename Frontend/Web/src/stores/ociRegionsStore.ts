import { create } from 'zustand';
import { fetchRegions, getRegionCapacity } from '../helpers/APIHelper';
import { Region, sortRegions } from '../helpers/regionsHelper';

interface OciRegionsStore {
  ociRegions: Region[] | null;
  loading: boolean;
  error: string | null;
  fetchOciRegions: (token: string) => Promise<void>;
  clearOciRegions: () => void;
}

let activeFetch: Promise<void> | null = null;

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

    try {
      const regionsResult = await fetchRegions();
      if (!regionsResult.success) {
        throw new Error(regionsResult.error);
      }
      const regions = sortRegions(
        regionsResult.data.regions.map<Region>((region) => ({
          regionId: region.regionId,
          displayName: region.displayName,
          enabled: true,
          displayOrder: region.displayOrder,
        }))
      );
      const regionsWithCapacity = await Promise.all(
        regions.map(async (region) => {
          const result = await getRegionCapacity(region.regionId, token);
          if (!result.success || result.data.regionId !== region.regionId) {
            return {
              ...region,
              capacity: {
                status: "unknown" as const,
              },
            };
          }

          return {
            ...region,
            capacity: {
              status: "known" as const,
              limit: result.data.capacityLimit,
              allocated: result.data.allocatedClientCount,
            },
          };
        }),
      );

      set({ ociRegions: regionsWithCapacity, loading: false });
    } catch (error) {
      set({ error: error instanceof Error ? error.message : 'Regions fetch failed', loading: false });
    }
  },

  clearOciRegions: () => {
    set({ ociRegions: null, error: null, loading: false });
  },
}));
