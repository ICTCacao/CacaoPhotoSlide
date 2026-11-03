import "./styles.css";
import { store } from "./store.ts";
import { mountApp } from "./app.ts";

window.addEventListener("DOMContentLoaded", () => mountApp(document.getElementById("app")!));
void store;
