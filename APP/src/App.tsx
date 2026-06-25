import React from "react";
import { HashRouter as Router, Routes, Route } from "react-router-dom";
import Home from "./pages/Home";
import Login from "./pages/Login";
import About from "./pages/About";
import CreateUser from "./pages/CreateUser";
import CreateUserSuccess from "./pages/CreateUserSuccess";
import PasswordReset from "./pages/PasswordReset";
import SyncRegions from "./pages/SyncRegions";

const App: React.FC = () => {
  return (
    <Router>
      <Routes>
        <Route path="/home" element={<Home />} />
        <Route path="/" element={<Login />} />
        <Route path="/login" element={<Login />} />
        <Route path="/auth" element={<PasswordReset />} />
        <Route path="/about" element={<About />} />
        <Route path="/create-user" element={<CreateUser />} />
        <Route path="/create-user-success" element={<CreateUserSuccess />} />
        <Route path="/sync-regions" element={<SyncRegions />} />
      </Routes>
    </Router>
  );
};

export default App;
