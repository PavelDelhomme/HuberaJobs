'use client'

import { createContext, useContext, useState, useEffect, ReactNode } from 'react'
import { useRouter } from 'next/navigation'
import { authService } from './api'
import {
  detectHuberaSession,
  quickLoginWithHuberaId,
  clearHuberaSession,
  type HuberaDetectResult,
} from './huberaId'

interface User {
  id: string
  email: string
  firstName: string
  lastName: string
  role: 'USER' | 'ADMIN' | 'SUPER_ADMIN'
  isActive: boolean
}

interface AuthContextType {
  user: User | null
  token: string | null
  loading: boolean
  login: (email: string, password: string) => Promise<void>
  logout: () => void
  isAuthenticated: boolean
  isAdmin: boolean
  huberaIdDetected: HuberaDetectResult | null
  checkHuberaId: () => Promise<HuberaDetectResult | null>
  continueWithHuberaId: () => Promise<boolean>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [token, setToken] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [huberaIdDetected, setHuberaIdDetected] = useState<HuberaDetectResult | null>(null)
  const router = useRouter()

  // ✅ Charger le token et profil au démarrage
  useEffect(() => {
    // Vérifier localStorage en priorité
    let storedToken = localStorage.getItem('token')
    
    // Si pas dans localStorage, vérifier les cookies
    if (!storedToken && typeof window !== 'undefined') {
      const cookies = document.cookie.split(';')
      const tokenCookie = cookies.find(c => c.trim().startsWith('token='))
      if (tokenCookie) {
        storedToken = tokenCookie.split('=')[1]
        // Synchroniser avec localStorage
        localStorage.setItem('token', storedToken)
      }
    }
    
    if (storedToken) {
      setToken(storedToken)
      loadUserProfile(storedToken)
    } else {
      setLoading(false)
    }
  }, [])

  const loadUserProfile = async (authToken: string) => {
    try {
      const response = await authService.getProfile()
      setUser(response.data.user)
    } catch (error) {
      console.error('Erreur chargement profil:', error)
      logout()
    } finally {
      setLoading(false)
    }
  }

  const login = async (email: string, password: string) => {
    try {
      const response = await authService.login(email, password)
      
      if (response.data.success) {
        const { token: newToken, user: newUser } = response.data
        
        setToken(newToken)
        setUser(newUser)
        
        // ✅ Sauvegarder dans localStorage ET cookies
        localStorage.setItem('token', newToken)
        
        // ✅ Sauvegarder aussi dans les cookies pour le middleware Next.js
        if (typeof window !== 'undefined') {
          document.cookie = `token=${newToken}; path=/; max-age=${7 * 24 * 60 * 60}; SameSite=Lax`
        }
        
        router.push('/backoffice')
      }
    } catch (error: any) {
      throw new Error(error.response?.data?.error || 'Erreur de connexion')
    }
  }

  const logout = () => {
    setUser(null)
    setToken(null)
    setHuberaIdDetected(null)
    
    // ✅ Supprimer du localStorage ET des cookies
    localStorage.removeItem('token')
    clearHuberaSession()
    
    // ✅ Supprimer aussi des cookies
    if (typeof window !== 'undefined') {
      document.cookie = 'token=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT'
    }
    
    router.push('/login')
  }

  const checkHuberaId = async (): Promise<HuberaDetectResult | null> => {
    if (user) return null
    try {
      const detected = await detectHuberaSession()
      setHuberaIdDetected(detected.found ? detected : null)
      return detected.found ? detected : null
    } catch {
      return null
    }
  }

  const continueWithHuberaId = async (): Promise<boolean> => {
    try {
      const result = await quickLoginWithHuberaId()
      if (!result) return false

      const newToken = result.accessToken
      const newUser: User = {
        id: result.userId,
        email: result.email,
        firstName: result.email.split('@')[0],
        lastName: '',
        role: 'USER',
        isActive: true,
      }

      setToken(newToken)
      setUser(newUser)
      setHuberaIdDetected(null)

      localStorage.setItem('token', newToken)
      if (typeof window !== 'undefined') {
        document.cookie = `token=${newToken}; path=/; max-age=${7 * 24 * 60 * 60}; SameSite=Lax`
      }

      router.push('/backoffice')
      return true
    } catch (error) {
      console.error('[HuberaID] continueWithHuberaId error:', error)
      return false
    }
  }

  // Check for Hubera ID session on mount if not logged in
  useEffect(() => {
    if (!loading && !user) {
      void checkHuberaId()
    }
  }, [loading, user])

  const value = {
    user,
    token,
    loading,
    login,
    logout,
    isAuthenticated: !!user && !!token,
    isAdmin: user?.role === 'ADMIN' || user?.role === 'SUPER_ADMIN',
    huberaIdDetected,
    checkHuberaId,
    continueWithHuberaId,
  }

  return (
    <AuthContext.Provider value={value}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider')
  }
  return context
}

