import { initializeApp } from "firebase/app";
import {
  EmailAuthProvider,
  getAuth,
  GoogleAuthProvider,
  reauthenticateWithCredential,
  reauthenticateWithPopup,
  sendPasswordResetEmail,
  signInWithEmailAndPassword,
  signInWithPopup,
  signOut,
  onAuthStateChanged,
  getIdToken,
} from "firebase/auth";

import { firebaseConfig } from "./Secrets/firebaseConfig";

// Initialize Firebase
const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const googleProvider = new GoogleAuthProvider();
googleProvider.setCustomParameters({
  prompt: "select_account",
});

const signInWithGoogle = () => signInWithPopup(auth, googleProvider);

export {
  auth,
  EmailAuthProvider,
  sendPasswordResetEmail,
  signInWithEmailAndPassword,
  signInWithGoogle,
  signOut,
  onAuthStateChanged,
  getIdToken,
  GoogleAuthProvider,
  googleProvider,
  reauthenticateWithCredential,
  reauthenticateWithPopup,
};
