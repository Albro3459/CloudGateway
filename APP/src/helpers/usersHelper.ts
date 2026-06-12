import { User } from "firebase/auth";
import { doc, getDoc, getFirestore } from "firebase/firestore";

export const getUserRole = async (user: User): Promise<string | null> => {
    try {
      const uid = user.uid;
      const db = getFirestore();
      const docRef = doc(db, "Roles", uid);
      const docSnap = await getDoc(docRef);
  
      if (docSnap.exists()) {
        const data = docSnap.data();
        return data.role || null;
      }
  
      console.warn(`Role document does not exist for user: ${uid}`);
      return null;
  
    } catch (error: any) {
      if (error.code === "permission-denied") {
        console.warn("Permission denied when trying to read role. Probably not an admin.");
      } else {
        console.error("Unexpected error getting user role:", error);
      }
  
      return null;
    }
};

export const isUserProvisioned = async (user: User): Promise<boolean> => {
    try {
      const db = getFirestore();
      const docRef = doc(db, "Users", user.uid);
      const docSnap = await getDoc(docRef);

      return docSnap.exists();
    } catch (error) {
      console.error("Unexpected error checking user provisioning:", error);
      return false;
    }
};
