import { initializeApp } from "firebase/app";
import {
  EmailAuthProvider,
  getAuth,
  GoogleAuthProvider,
  linkWithCredential,
  linkWithPopup,
  OAuthProvider,
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

const appleProvider = new OAuthProvider("apple.com");
appleProvider.addScope("email");
appleProvider.addScope("name");

const signInWithApple = () => signInWithPopup(auth, appleProvider);

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
  signInWithApple,
  signInWithGoogle,
  signOut,
  onAuthStateChanged,
  getIdToken,
  linkWithCredential,
  linkWithPopup,
  appleProvider,
  GoogleAuthProvider,
  googleProvider,
  OAuthProvider,
  reauthenticateWithCredential,
  reauthenticateWithPopup,
};
