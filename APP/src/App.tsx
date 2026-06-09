import React from "react";
import { HashRouter as Router, Routes, Route } from "react-router-dom";
import Home from "./pages/Home";
import Login from "./pages/Login";
import VPNSuccess from "./pages/VPNSuccess";
import About from "./pages/About";
import CreateUser from "./pages/CreateUser";
import CreateUserSuccess from "./pages/CreateUserSuccess";
import PasswordReset from "./pages/PasswordReset";

const App: React.FC = () => {
  return (
    <Router>
      <Routes>
        <Route path="/home" element={<Home />} />
        <Route path="/" element={<Login />} />
        <Route path="/login" element={<Login />} />
        <Route path="/auth" element={<PasswordReset />} />
        <Route path="/vpn-success" element={<VPNSuccess />} />
        <Route path="/about" element={<About />} />
        <Route path="/create-user" element={<CreateUser />} />
        <Route path="/create-user-success" element={<CreateUserSuccess />} />
      </Routes>
    </Router>
  );
};

export default App;
