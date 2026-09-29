"use client";

/** The page's language for client components: the root layout of each language wraps the page in `LangProvider`. */
import { createContext, useContext } from "react";
import { dict, type Lang } from "./index";

const LangContext = createContext<Lang>("en");

export function LangProvider({ lang, children }: { lang: Lang; children: React.ReactNode }) {
  return <LangContext.Provider value={lang}>{children}</LangContext.Provider>;
}

export const useLang = () => useContext(LangContext);
export const useDict = () => dict(useContext(LangContext));
