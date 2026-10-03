import React from "react";
import { HashRouter as Router, Routes, Route } from "react-router-dom";
import Home from "./pages/Home";
import Login from "./pages/Login";
import About from "./pages/About";
import PasswordReset from "./pages/PasswordReset";
import PrivacyPolicy from "./pages/PrivacyPolicy";
import ServerHealth from "./pages/ServerHealth";
import DeviceApproval from "./pages/DeviceApproval";

const App: React.FC = () => {
  return (
    <Router>
      <Routes>
        <Route path="/home" element={<Home />} />
        <Route path="/" element={<Login />} />
        <Route path="/login" element={<Login />} />
        <Route path="/auth" element={<PasswordReset />} />
        <Route path="/auth/code" element={<DeviceApproval />} />
        <Route path="/about" element={<About />} />
        <Route path="/privacy" element={<PrivacyPolicy />} />
        <Route path="/server-health" element={<ServerHealth />} />
      </Routes>
    </Router>
  );
};

export default App;
