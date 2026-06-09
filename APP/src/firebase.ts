import { initializeApp } from "firebase/app";
import { getAuth, sendPasswordResetEmail, signInWithEmailAndPassword, signOut, onAuthStateChanged, getIdToken } from "firebase/auth";

import { firebaseConfig } from "./Secrets/firebaseConfig";

// Initialize Firebase
const app = initializeApp(firebaseConfig);
const auth = getAuth(app);

export { auth, sendPasswordResetEmail, signInWithEmailAndPassword, signOut, onAuthStateChanged, getIdToken };
