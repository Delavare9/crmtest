// Вход и текущий пользователь.
//
// Сессию хранит supabase-js, а роль и имя берутся из таблицы profiles:
// интерфейс не доверяет ничему, что можно подменить в браузере, — роль
// всё равно проверяет база в каждом запросе. Здесь она нужна только чтобы
// решить, какие экраны и кнопки показать.
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "./supabase";
import type { Me } from "./types";

type AuthState = {
  session: Session | null;
  me: Me | null;
  // true, пока не ясно, вошёл ли пользователь (первая загрузка страницы).
  loading: boolean;
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [session, setSession] = useState<Session | null>(null);
  const [sessionReady, setSessionReady] = useState(false);

  useEffect(() => {
    // Сессия из localStorage после перезагрузки страницы.
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setSessionReady(true);
    });

    // Вход, выход и обновление токена из любой вкладки.
    const { data } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  const userId = session?.user.id ?? null;

  // Профиль загружается только когда есть пользователь.
  const profile = useQuery({
    queryKey: ["me", userId],
    enabled: userId !== null,
    queryFn: async (): Promise<Me | null> => {
      const { data, error } = await supabase
        .from("profiles")
        .select("id, role, full_name")
        .eq("id", userId!)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
  });

  const value: AuthState = {
    session,
    me: profile.data ?? null,
    loading: !sessionReady || (userId !== null && profile.isPending),
    signIn: async (email, password) => {
      const { error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) throw error;
    },
    signOut: async () => {
      await supabase.auth.signOut();
      // Данные прошлого пользователя не должны мелькнуть следующему.
      queryClient.clear();
    },
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth вызывается вне AuthProvider");
  return ctx;
}

// Для экранов за входом: пользователь гарантированно есть (это обеспечивает
// RequireAuth в маршрутах), поэтому возвращаем его без проверки на null.
export function useMe(): Me {
  const { me } = useAuth();
  if (!me) throw new Error("useMe вызывается до входа пользователя");
  return me;
}
