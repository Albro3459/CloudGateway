import { create } from 'zustand';
import { fetchRegions, getRegionCapacity } from '../helpers/APIHelper';
import { Region, sortRegions } from '../helpers/regionsHelper';

interface OciRegionsStore {
  ociRegions: Region[] | null;
  loading: boolean;
  error: string | null;
  fetchOciRegions: (token: string, fetchGeneration: number) => Promise<void>;
  clearOciRegions: () => void;
}

type ActiveFetch = {
  token: string;
  generation: number;
  promise: Promise<void>;
};

let activeFetch: ActiveFetch | null = null;
let loadedToken: string | null = null;
let generation = 0;

export const fetchOciRegions = (token: string, force = false) : Promise<void> => {
  const store = useOciRegionsStore.getState();
  if (activeFetch?.token === token) return activeFetch.promise;
  if (!force && !activeFetch && loadedToken === token && (store.loading || store.ociRegions?.length)) {
    return Promise.resolve();
  }

  const fetchGeneration = generation + 1;
  generation = fetchGeneration;
  const promise = store.fetchOciRegions(token, fetchGeneration).finally(() => {
    if (activeFetch?.token === token && activeFetch.generation === fetchGeneration) {
      activeFetch = null;
    }
  });
  activeFetch = { token, generation: fetchGeneration, promise };

  return promise;
};

export const useOciRegionsStore = create<OciRegionsStore>((set) => ({
  ociRegions: null,
  loading: false,
  error: null,

  fetchOciRegions: async (token: string, fetchGeneration: number) => {
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

      if (generation === fetchGeneration) {
        loadedToken = token;
        set({ ociRegions: regionsWithCapacity, loading: false });
      }
    } catch (error) {
      if (generation === fetchGeneration) {
        set({ error: error instanceof Error ? error.message : 'Regions fetch failed', loading: false });
      }
    }
  },

  clearOciRegions: () => {
    generation += 1;
    activeFetch = null;
    loadedToken = null;
    set({ ociRegions: null, error: null, loading: false });
  },
}));
