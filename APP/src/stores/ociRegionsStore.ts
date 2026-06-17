import { create } from 'zustand';
import { collection, getDocs, getFirestore, query, where } from 'firebase/firestore';
import { parseRegionDocument, Region, sortRegions } from '../helpers/regionsHelper';

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
    void token;

    try {
      const db = getFirestore();
      // Security rules only allow provisioned users to read enabled regions, so
      // the query must match or it is rejected outright (an unprovisioned user's
      // read is denied, which surfaces as a generic access error at sign-in).
      const regionsSnapshot = await getDocs(query(collection(db, "Regions"), where("enabled", "==", true)));
      const regions = sortRegions(
        regionsSnapshot.docs.reduce<Region[]>((result, regionDoc) => {
          const region = parseRegionDocument(regionDoc.id, regionDoc.data());
          if (region) {
            result.push(region);
          }

          return result;
        }, [])
      );

      set({ ociRegions: regions, loading: false });
    } catch (error) {
      set({ error: error instanceof Error ? error.message : 'Regions fetch failed', loading: false });
    }
  },

  clearOciRegions: () => {
    set({ ociRegions: null, error: null, loading: false });
  },
}));
