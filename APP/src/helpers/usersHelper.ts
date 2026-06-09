import { User } from "firebase/auth";
import { doc, getDoc, getFirestore } from "firebase/firestore";
import { CREATE_USER_API_PATH } from "./apiEndpoints";

export const createUser = async (email: string, password: string, token: string) => {
    try {
        const myHeaders = new Headers();
        myHeaders.append("Authorization", `Bearer ${token}`);
        myHeaders.append("Content-Type", "application/json");

        const raw = JSON.stringify({
            "email": email,
            "password": password
        });

        const requestOptions: RequestInit = {
            method: "POST",
            headers: myHeaders,
            body: raw,
            redirect: "follow"
        };

        const response = await fetch(CREATE_USER_API_PATH, requestOptions);
        const result = await response.json();

        if (!response.ok) {
            return {
                success: false,
                error: result?.error || `Error ${response.status}`
            };
        }

        return {
            success: true,
            data: result.uuid_created
        };
        
    } catch (error) {
        console.error("Create User API Error:", error);
        return {
            success: false,
            error: error instanceof Error ? error.message : "Unknown Create User API Error"
        };
    }    
};

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
