'use client'
import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { useAuth } from '@/lib/auth';
import { useTheme } from '@/lib/theme';

export default function LoginPage() {
  const [email, setEmail] = useState('pavel@jobbingtrack.com');
  const [password, setPassword] = useState('password123');
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [huberaLoading, setHuberaLoading] = useState(false);
  const [error, setError] = useState('');
  const router = useRouter();
  const { login, isAuthenticated, user, huberaIdDetected, continueWithHuberaId } = useAuth();
  const { actualTheme, toggleTheme } = useTheme();

  // ✅ Si déjà connecté, rediriger automatiquement
  useEffect(() => {
    if (isAuthenticated && user) {
      console.log('✅ Déjà connecté, redirection vers /backoffice...');
      router.push('/backoffice');
    }
  }, [isAuthenticated, user, router]);

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError('');

    try {
      console.log('🔐 Tentative de connexion...');
      
      // ✅ UTILISER LA FONCTION login() du contexte d'authentification
      await login(email, password);
      
      console.log('✅ Login réussi, redirection vers /backoffice...');
      
      // La redirection est gérée automatiquement par le useEffect ci-dessus
      // ou directement par la fonction login() dans auth.tsx
      
    } catch (err: any) {
      console.error('❌ Login error:', err);
      setError(err.message || 'Erreur de connexion');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-blue-50 via-white to-purple-50 dark:from-gray-950 dark:via-gray-900 dark:to-gray-950 px-4 py-8 sm:px-6 lg:px-8">
      <div className="max-w-md w-full space-y-6 sm:space-y-8">
        {/* Theme Toggle - Position absolue sur mobile */}
        <div className="absolute top-4 right-4 sm:static sm:flex sm:justify-end">
          <button
            onClick={toggleTheme}
            className={`flex items-center gap-2 px-3 sm:px-4 py-2 sm:py-2.5 rounded-lg sm:rounded-xl transition-all shadow-lg hover:shadow-xl transform hover:scale-105 ${
              actualTheme === 'dark'
                ? 'bg-gray-800 text-gray-100 hover:bg-gray-700 border border-gray-700'
                : 'bg-white text-gray-700 hover:bg-gray-50 border border-gray-200'
            }`}
            title={actualTheme === 'dark' ? 'Passer en mode clair' : 'Passer en mode sombre'}
          >
            <span className="text-xl sm:text-2xl">{actualTheme === 'dark' ? '🌙' : '☀️'}</span>
            <span className="text-xs sm:text-sm font-medium hidden sm:inline">
              {actualTheme === 'dark' ? 'Sombre' : 'Clair'}
            </span>
          </button>
        </div>

        {/* Card principale avec shadow et bordure */}
        <div className="bg-white dark:bg-gray-800 rounded-2xl sm:rounded-3xl shadow-2xl border border-gray-100 dark:border-gray-700 overflow-hidden">
          {/* Header avec gradient */}
          <div className="bg-gradient-to-r from-blue-600 to-purple-600 dark:from-blue-700 dark:to-purple-700 px-6 sm:px-8 py-8 sm:py-10 text-center">
            <div className="text-5xl sm:text-6xl mb-3 sm:mb-4 animate-bounce">🎯</div>
            <h2 className="text-2xl sm:text-3xl lg:text-4xl font-bold text-white drop-shadow-lg">
              JobbingTrack
            </h2>
            <p className="mt-2 sm:mt-3 text-sm sm:text-base text-blue-100">
              Backoffice Administrateur
            </p>
          </div>

          {/* Formulaire */}
          <form className="px-6 sm:px-8 py-6 sm:py-8 space-y-5 sm:space-y-6" onSubmit={handleLogin}>
            {/* Hubera ID Quick Login */}
            {huberaIdDetected?.found && huberaIdDetected.email && (
              <div className="bg-gradient-to-br from-indigo-50 to-purple-50 dark:from-indigo-900/20 dark:to-purple-900/20 border-2 border-indigo-200 dark:border-indigo-700 rounded-xl sm:rounded-2xl p-4 sm:p-5">
                <div className="text-center mb-3">
                  <span className="text-2xl">🔐</span>
                  <p className="text-sm font-semibold text-indigo-700 dark:text-indigo-300 mt-1">
                    Compte Hubera ID détecté
                  </p>
                </div>
                <button
                  type="button"
                  disabled={huberaLoading}
                  onClick={async () => {
                    setHuberaLoading(true);
                    setError('');
                    try {
                      const success = await continueWithHuberaId();
                      if (!success) {
                        setError('Connexion Hubera ID impossible. Essayez avec email/mot de passe.');
                      }
                    } catch (err: any) {
                      setError(err.message || 'Erreur Hubera ID');
                    } finally {
                      setHuberaLoading(false);
                    }
                  }}
                  className="w-full py-3 sm:py-4 px-4 bg-gradient-to-r from-indigo-600 to-purple-600 hover:from-indigo-700 hover:to-purple-700 text-white rounded-xl font-bold text-sm sm:text-base shadow-lg hover:shadow-xl disabled:opacity-50 disabled:cursor-not-allowed transform transition-all duration-200 hover:scale-[1.02]"
                >
                  {huberaLoading ? (
                    <span className="flex items-center justify-center gap-2">
                      <span className="animate-spin">⏳</span>
                      <span>Connexion...</span>
                    </span>
                  ) : (
                    <span>Continuer avec {huberaIdDetected.email}</span>
                  )}
                </button>
                <p className="text-xs text-center text-indigo-600 dark:text-indigo-400 mt-2">
                  Connexion automatique via Hubera ID (SSO)
                </p>
              </div>
            )}

            {error && (
              <div className="bg-red-50 dark:bg-red-900/20 border-2 border-red-200 dark:border-red-800 text-red-700 dark:text-red-300 px-4 py-3 sm:py-4 rounded-xl flex items-start gap-3 animate-shake">
                <span className="text-xl sm:text-2xl">❌</span>
                <span className="text-sm sm:text-base flex-1">{error}</span>
              </div>
            )}

            <div className="space-y-1">
              <label className="block text-sm sm:text-base font-semibold text-gray-700 dark:text-gray-300 mb-2">
                📧 Email
              </label>
              <input
                type="email"
                required
                autoComplete="email"
                className="w-full px-4 sm:px-5 py-3 sm:py-4 text-base sm:text-lg border-2 border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-900 dark:text-gray-100 rounded-xl focus:ring-4 focus:ring-blue-500/50 dark:focus:ring-blue-400/50 focus:border-blue-500 dark:focus:border-blue-400 transition-all"
                placeholder="votre.email@exemple.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </div>

            <div className="space-y-1">
              <label className="block text-sm sm:text-base font-semibold text-gray-700 dark:text-gray-300 mb-2">
                🔐 Mot de passe
              </label>
              <div className="relative">
                <input
                  type={showPassword ? "text" : "password"}
                  required
                  autoComplete="current-password"
                  className="w-full px-4 sm:px-5 py-3 sm:py-4 pr-12 sm:pr-14 text-base sm:text-lg border-2 border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-900 dark:text-gray-100 rounded-xl focus:ring-4 focus:ring-blue-500/50 dark:focus:ring-blue-400/50 focus:border-blue-500 dark:focus:border-blue-400 transition-all"
                  placeholder="••••••••"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                />
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  className="absolute right-3 sm:right-4 top-1/2 -translate-y-1/2 text-2xl sm:text-3xl hover:scale-110 transition-transform touch-manipulation"
                  title={showPassword ? "Masquer le mot de passe" : "Afficher le mot de passe"}
                >
                  {showPassword ? '🙈' : '👁️'}
                </button>
              </div>
            </div>

            <button
              type="submit"
              disabled={loading}
              className="w-full py-4 sm:py-5 px-4 bg-gradient-to-r from-blue-600 to-purple-600 dark:from-blue-500 dark:to-purple-500 hover:from-blue-700 hover:to-purple-700 dark:hover:from-blue-600 dark:hover:to-purple-600 text-white rounded-xl sm:rounded-2xl font-bold text-base sm:text-lg shadow-lg hover:shadow-xl disabled:opacity-50 disabled:cursor-not-allowed transform transition-all duration-200 hover:scale-[1.02] active:scale-[0.98] touch-manipulation"
            >
              {loading ? (
                <span className="flex items-center justify-center gap-2">
                  <span className="animate-spin">⏳</span>
                  <span>Connexion en cours...</span>
                </span>
              ) : (
                <span className="flex items-center justify-center gap-2">
                  <span>🚀</span>
                  <span>Se connecter</span>
                </span>
              )}
            </button>

            {/* Info compte de test - Card améliorée */}
            <div className="bg-gradient-to-br from-blue-50 to-indigo-50 dark:from-blue-900/20 dark:to-indigo-900/20 border-2 border-blue-200 dark:border-blue-700 rounded-xl sm:rounded-2xl p-4 sm:p-5">
              <div className="flex items-start gap-3">
                <span className="text-2xl sm:text-3xl">🧪</span>
                <div className="flex-1 text-xs sm:text-sm text-blue-900 dark:text-blue-100">
                  <p className="font-bold mb-2 text-sm sm:text-base">Compte de test :</p>
                  <div className="space-y-1">
                    <p><strong>Email:</strong> pavel@jobbingtrack.com</p>
                    <p><strong>Mot de passe:</strong> password123</p>
                  </div>
                  <p className="mt-3 text-xs text-blue-700 dark:text-blue-300 italic">
                    💡 Les champs sont pré-remplis pour faciliter les tests
                  </p>
                </div>
              </div>
            </div>
          </form>

          {/* Footer */}
          <div className="px-6 sm:px-8 pb-6 sm:pb-8 text-center">
            <p className="text-xs sm:text-sm text-gray-500 dark:text-gray-400">
              © 2025 JobbingTrack • Version 1.0.0
            </p>
          </div>
        </div>

        {/* Message d'aide mobile */}
        <div className="text-center text-xs sm:text-sm text-gray-600 dark:text-gray-400 px-4">
          <p className="sm:hidden">📱 Optimisé pour mobile</p>
          <p className="hidden sm:block">🖥️ Interface responsive - Accessible sur tous vos appareils</p>
        </div>
      </div>

      <style jsx>{`
        @keyframes shake {
          0%, 100% { transform: translateX(0); }
          10%, 30%, 50%, 70%, 90% { transform: translateX(-5px); }
          20%, 40%, 60%, 80% { transform: translateX(5px); }
        }
        .animate-shake {
          animation: shake 0.5s ease-in-out;
        }
      `}</style>
    </div>
  );
}
