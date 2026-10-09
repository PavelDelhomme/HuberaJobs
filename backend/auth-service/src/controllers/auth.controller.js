const { PrismaClient } = require('@prisma/client');
const { validationResult } = require('express-validator');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const axios = require('axios');
const logger = require('../utils/logger');
const emailService = require('../services/emailService');
const { prisma, findUserByLoginEmail } = require('../utils/prismaClient');

const register = async (req, res, next) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      // Log d'échec de validation
      await sendSecurityLog('warning', 'authentication', 'registration_validation_error', 'Échec de validation des données d\'inscription', {
        sourceIP: req.ip,
        endpoint: req.path,
        method: req.method,
        userAgent: req.get('User-Agent'),
        riskScore: 15,
        metadata: { errors: errors.array() }
      });

      return res.status(400).json({
        success: false,
        errors: errors.array()
      });
    }

    const { email, password, firstName, lastName, phone, role } = req.body;
    const clientIP = req.ip;
    const userAgent = req.get('User-Agent');

    // Vérifier si l'utilisateur existe déjà (avec gestion d'erreur P2021)
    let existingUser = null;
    try {
      existingUser = await findUserByLoginEmail(email);
    } catch (error) {
      // Si la table User n'existe pas (P2021), on considère qu'aucun utilisateur n'existe
      if (error.code === 'P2021' || error.message?.includes('does not exist')) {
        existingUser = null;
      } else {
        throw error;
      }
    }

    if (existingUser) {
      // Log de tentative d'inscription avec email existant
      await sendSecurityLog('warning', 'authentication', 'registration_duplicate_email', 'Tentative d\'inscription avec un email déjà existant', {
        sourceIP: clientIP,
        endpoint: req.path,
        method: req.method,
        userAgent,
        riskScore: 20,
        metadata: {
          attemptedEmail: email,
          existingUserId: existingUser.id
        }
      });

      return res.status(409).json({
        success: false,
        error: 'Un compte avec cette adresse email existe déjà'
      });
    }

    // Valider le rôle
    const validRoles = ['USER', 'ADMIN', 'SUPER_ADMIN', 'TESTER'];
    const userRole = validRoles.includes(role) ? role : 'USER';

    // Hasher le mot de passe
    const hashedPassword = await bcrypt.hash(password, 12);

    // Générer un token de vérification d'email (valide 24h)
    const verificationToken = crypto.randomBytes(32).toString('hex');
    const verificationTokenExpiry = new Date(Date.now() + 24 * 60 * 60 * 1000); // 24 heures

    // Créer l'utilisateur
    const user = await prisma.user.create({
      data: {
        email: email.toLowerCase(),
        password: hashedPassword,
        firstName,
        lastName,
        phone,
        role: userRole,
        verificationToken,
        verificationTokenExpiry,
        emailVerified: false
      }
    });

    // Générer le token JWT avec le rôle
    const token = jwt.sign(
      { 
        userId: user.id, 
        email: user.email,
        role: user.role || 'USER' // Rôle de l'utilisateur
      },
      process.env.JWT_SECRET,
      { expiresIn: '7d' }
    );

    // Log de succès d'inscription
    await sendSecurityLog('info', 'authentication', 'registration_success', 'Inscription utilisateur réussie', {
      sourceIP: clientIP,
      endpoint: req.path,
      method: req.method,
      userAgent,
      userId: user.id,
      riskScore: 5,
      metadata: {
        userEmail: user.email,
        userRole: user.role,
        registrationComplete: true,
        emailVerified: false
      }
    });

    // Envoyer email de vérification (async - prioritaire)
    // Le service construit maintenant l'URL lui-même
    emailService.sendVerificationEmail(user, verificationToken).catch(error => {
      logger.error('Erreur envoi email vérification:', error);
    });

    // Envoyer aussi email de bienvenue (async)
    emailService.sendWelcomeEmail(user).catch(error => {
      logger.error('Erreur envoi email bienvenue:', error);
    });

    // Retourner la réponse (sans le mot de passe)
    const { password: _, resetToken, resetTokenExpiry, ...userWithoutPassword } = user;

    res.status(201).json({
      success: true,
      message: 'Compte créé avec succès. Un email de vérification a été envoyé à votre adresse.',
      user: userWithoutPassword,
      token,
      emailVerificationRequired: true
    });

    logger.info(`Nouvel utilisateur inscrit: ${user.email} - Email de vérification envoyé`);
  } catch (error) {
    logger.error('Erreur inscription:', error);
    next(error);
  }
};

const login = async (req, res, next) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      // Log d'échec de validation
      await sendSecurityLog('warning', 'authentication', 'validation_error', 'Échec de validation des données de connexion', {
        sourceIP: req.ip,
        endpoint: req.path,
        method: req.method,
        userAgent: req.get('User-Agent'),
        riskScore: 15,
        metadata: { errors: errors.array() }
      });

      return res.status(400).json({
        success: false,
        errors: errors.array()
      });
    }

    const { email, password } = req.body;
    const clientIP = req.ip;
    const userAgent = req.get('User-Agent');

    // Trouver l'utilisateur avec fallback P2021 (table User n'existe pas)
    let user;
    
    // Vérifier d'abord si prisma.user existe (au cas où le modèle n'est pas généré)
    if (!prisma.user || typeof prisma.user.findUnique !== 'function') {
      if (process.env.NODE_ENV !== 'production') {
        logger.warn('⚠️ Prisma User model non disponible, utilisation du mode développement');
        // IMPORTANT: Vérifier que l'email correspond à admin@jobbingtrack.test
        if (email.toLowerCase() === 'admin@jobbingtrack.test') {
          user = {
            id: 'dev_user_1',
            email: email.toLowerCase(),
            password: '$2b$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', // password123
            firstName: 'Dev',
            lastName: 'User',
            role: 'SUPER_ADMIN',
            isActive: true,
            emailVerified: true
          };
          logger.info('✅ Utilisateur mock créé pour admin@jobbingtrack.test (prisma.user non disponible)');
        } else {
          logger.warn(`⚠️ Email ${email} ne correspond pas à admin@jobbingtrack.test, utilisateur mock non créé`);
          user = null;
        }
      } else {
        return res.status(500).json({
          success: false,
          error: 'Service d\'authentification non disponible'
        });
      }
    } else {
      try {
        // Essayer de récupérer l'utilisateur depuis la base de données
        user = await findUserByLoginEmail(email);
      } catch (error) {
        // Fallback si table User n'existe pas (P2021) - Mode développement
        // Capturer TOUTES les erreurs Prisma liées à la table manquante
        const isTableError = error.code === 'P2021' || 
                            error.code === 'P2022' ||
                            (error.message && (
                              error.message.includes('does not exist') || 
                              error.message.includes('Table') || 
                              error.message.includes('public.User') ||
                              error.message.includes('public."User"') ||
                              error.message.includes('relation') && error.message.includes('does not exist')
                            ));
        
        if (isTableError && process.env.NODE_ENV !== 'production') {
          logger.warn('⚠️ Table User non trouvée (erreur Prisma), utilisation du mode développement');
          logger.warn(`   Code erreur: ${error.code}, Message: ${error.message}`);
          // Retourner un utilisateur mock pour le développement
          // IMPORTANT: Vérifier que l'email correspond à admin@jobbingtrack.test
          if (email.toLowerCase() === 'admin@jobbingtrack.test') {
            user = {
              id: 'dev_user_1',
              email: email.toLowerCase(),
              password: '$2b$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', // password123
              firstName: 'Dev',
              lastName: 'User',
              role: 'SUPER_ADMIN',
              isActive: true,
              emailVerified: true
            };
            logger.info('✅ Utilisateur mock créé pour admin@jobbingtrack.test');
          } else {
            logger.warn(`⚠️ Email ${email} ne correspond pas à admin@jobbingtrack.test, utilisateur mock non créé`);
            user = null;
          }
        } else {
          // Pour toute autre erreur, logger et relancer
          logger.error('Erreur lors de la récupération de l\'utilisateur:', error);
          throw error;
        }
      }
    }

    // Vérifier l'utilisateur et le mot de passe
    if (!user) {
      // En développement : accepter un utilisateur de secours si la base est vide (sans perte de données)
      const fallbackEmail = (process.env.ADMIN_EMAIL || 'admin@jobbingtrack.test').toLowerCase();
      const fallbackPassword = process.env.ADMIN_PASSWORD || 'password123';
      if (process.env.NODE_ENV !== 'production' && email.toLowerCase() === fallbackEmail && password === fallbackPassword) {
        logger.info('✅ Connexion avec utilisateur de secours (base vide ou aucun utilisateur trouvé)');
        user = {
          id: 'dev_fallback_1',
          email: fallbackEmail,
          password: '$2b$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
          firstName: 'Admin',
          lastName: 'Backoffice',
          role: 'SUPER_ADMIN',
          isActive: true,
          emailVerified: true
        };
      }
    }

    if (!user) {
      logger.warn(`⚠️ Utilisateur non trouvé pour ${email}`);
      await sendSecurityLog('warning', 'authentication', 'login_failure', 'Échec d\'authentification - utilisateur non trouvé', {
        sourceIP: clientIP,
        endpoint: req.path,
        method: req.method,
        userAgent,
        riskScore: 25,
        metadata: {
          attemptedEmail: email,
          reason: 'user_not_found'
        }
      });

      return res.status(401).json({
        success: false,
        error: 'Invalid email or password'
      });
    }

    // Refuser le login si l'email n'est pas encore vérifié (sauf mock/fallback)
    if (user && user.id !== 'dev_user_1' && user.id !== 'dev_fallback_1' && user.emailVerified === false) {
      logger.warn(`⚠️ Connexion refusée : email non vérifié pour ${email}`);
      await sendSecurityLog('warning', 'authentication', 'login_email_not_verified', 'Tentative de connexion avec email non vérifié', {
        sourceIP: clientIP,
        endpoint: req.path,
        method: req.method,
        userAgent,
        riskScore: 20,
        metadata: { attemptedEmail: email }
      });
      return res.status(401).json({
        success: false,
        error: 'Veuillez vérifier votre email avant de vous connecter.',
        code: 'EMAIL_NOT_VERIFIED'
      });
    }

    // Pour l'utilisateur mock / fallback, mot de passe déjà vérifié
    if (user.id === 'dev_fallback_1') {
      logger.info('✅ Authentification réussie avec utilisateur de secours (dev_fallback_1)');
    } else if (user.id === 'dev_user_1' && password === 'password123') {
      logger.info('✅ Authentification réussie avec utilisateur mock (dev_user_1)');
    } else {
      // Vérifier le mot de passe pour les utilisateurs réels
      const passwordMatch = await bcrypt.compare(password, user.password);
      if (!passwordMatch) {
        logger.warn(`⚠️ Mot de passe incorrect pour ${email} (utilisateur mock: ${user.id === 'dev_user_1'})`);
        await sendSecurityLog('warning', 'authentication', 'login_failure', 'Échec d\'authentification - mot de passe incorrect', {
          sourceIP: clientIP,
          endpoint: req.path,
          method: req.method,
          userAgent,
          riskScore: 25,
          metadata: {
            attemptedEmail: email,
            reason: 'wrong_password',
            isMockUser: user.id === 'dev_user_1'
          }
        });

        return res.status(401).json({
          success: false,
          error: 'Invalid email or password'
        });
      }
    }

    // ✅ Mettre à jour le lastLoginAt pour le tracking des sessions actives (si la table existe)
    // Ne pas mettre à jour si c'est l'utilisateur mock ou de secours
    if (user.id !== 'dev_user_1' && user.id !== 'dev_fallback_1' && prisma.user && typeof prisma.user.update === 'function') {
      try {
        await prisma.user.update({
          where: { id: user.id },
          data: {
            lastLoginAt: new Date(),
            loginCount: (user.loginCount ?? 0) + 1
          }
        });
      } catch (error) {
        // Ignorer toutes les erreurs Prisma en mode développement (table peut ne pas exister)
        if (process.env.NODE_ENV !== 'production') {
          logger.warn('⚠️ Impossible de mettre à jour lastLoginAt (mode développement)');
        } else {
          logger.error('Erreur lors de la mise à jour lastLoginAt:', error);
        }
      }
    }

    // Générer le token JWT avec le rôle
    const token = jwt.sign(
      { 
        userId: user.id, 
        email: user.email,
        role: user.role || 'USER' // Rôle de l'utilisateur
      },
      process.env.JWT_SECRET,
      { expiresIn: '7d' }
    );

    // Log de succès de connexion
    await sendSecurityLog('info', 'authentication', 'login_success', 'Connexion utilisateur réussie', {
      sourceIP: clientIP,
      endpoint: req.path,
      method: req.method,
      userAgent,
      userId: user.id,
      riskScore: 5,
      metadata: {
        userEmail: user.email,
        userRole: user.role,
        tokenGenerated: true
      }
    });

    // Retourner la réponse (sans le mot de passe)
    const { password: _, resetToken, resetTokenExpiry, ...userWithoutPassword } = user;

    // ✅ Configurer le cookie avec le token
    res.cookie('token', token, {
      httpOnly: false, // Permettre la lecture côté client
      secure: false, // Désactivé en développement
      sameSite: 'lax', // Politique SameSite
      maxAge: 7 * 24 * 60 * 60 * 1000, // 7 jours en millisecondes
      path: '/'
    });

    res.json({
      success: true,
      message: 'Connexion réussie',
      user: userWithoutPassword,
      token,
      refreshToken: jwt.sign(
        { userId: user.id, type: 'refresh' },
        process.env.JWT_REFRESH_SECRET || process.env.JWT_SECRET,
        { expiresIn: '30d' }
      )
    });

    logger.info(`Connexion utilisateur: ${user.email}`);
  } catch (error) {
    logger.error('Erreur connexion:', error);
    next(error);
  }
};

const verifyPassword = async (req, res, next) => {
  try {
    const { currentPassword } = req.body || {};
    if (!currentPassword || typeof currentPassword !== 'string') {
      return res.status(400).json({
        success: false,
        error: 'Mot de passe actuel requis'
      });
    }

    const userId = req.user.id;

    if (userId === 'dev_fallback_1' && process.env.NODE_ENV !== 'production') {
      const fallbackPassword = process.env.ADMIN_PASSWORD || 'password123';
      if (currentPassword !== fallbackPassword) {
        return res.status(401).json({ success: false, error: 'Mot de passe incorrect' });
      }
      return res.json({ success: true, message: 'Mot de passe vérifié' });
    }

    if (userId === 'dev_user_1' && process.env.NODE_ENV !== 'production') {
      if (currentPassword !== 'password123') {
        return res.status(401).json({ success: false, error: 'Mot de passe incorrect' });
      }
      return res.json({ success: true, message: 'Mot de passe vérifié' });
    }

    let user;
    try {
      user = await prisma.user.findUnique({
        where: { id: userId },
        select: { id: true, email: true, password: true }
      });
    } catch (dbError) {
      if (dbError.code === 'P2021' && process.env.NODE_ENV === 'development') {
        const fallbackPassword = process.env.ADMIN_PASSWORD || 'password123';
        if (currentPassword !== fallbackPassword) {
          return res.status(401).json({ success: false, error: 'Mot de passe incorrect' });
        }
        return res.json({ success: true, message: 'Mot de passe vérifié' });
      }
      throw dbError;
    }

    if (!user?.password) {
      return res.status(404).json({ success: false, error: 'Utilisateur non trouvé' });
    }

    const passwordMatch = await bcrypt.compare(currentPassword, user.password);
    if (!passwordMatch) {
      logger.warn(`Échec vérification mot de passe pour ${user.email}`);
      return res.status(401).json({ success: false, error: 'Mot de passe incorrect' });
    }

    return res.json({ success: true, message: 'Mot de passe vérifié' });
  } catch (error) {
    logger.error('Erreur vérification mot de passe:', error);
    next(error);
  }
};

const getProfile = async (req, res, next) => {
  try {
    const userId = req.user.id; // ✅ Corrigé : req.user.id au lieu de req.user.userId

    let user;
    try {
      user = await prisma.user.findUnique({
        where: { id: userId },
        select: {
          id: true,
          email: true,
          firstName: true,
          lastName: true,
          phone: true,
          profilePicture: true,
          role: true,
          isActive: true,
          createdAt: true,
          updatedAt: true
          // ✅ Supprimé _count car le schéma auth-service ne contient pas ces relations
        }
      });
    } catch (dbError) {
      // Si la table User n'existe pas, retourner l'utilisateur depuis req.user en développement
      if (dbError.code === 'P2021' && process.env.NODE_ENV === 'development') {
        logger.warn('Table User non trouvée, utilisation des données du token. Exécutez: make db-push-all');
        // Retourner les données de l'utilisateur depuis req.user (déjà authentifié)
        user = {
          id: req.user.id,
          email: req.user.email,
          firstName: req.user.firstName || 'Admin',
          lastName: req.user.lastName || 'User',
          phone: req.user.phone || null,
          profilePicture: req.user.profilePicture || null,
          role: req.user.role || 'ADMIN',
          isActive: true,
          createdAt: new Date(),
          updatedAt: new Date()
        };
      } else {
        throw dbError;
      }
    }

    if (!user) {
      // En développement, si l'utilisateur n'est pas trouvé mais qu'on a req.user, utiliser ces données
      if (process.env.NODE_ENV === 'development' && req.user) {
        // En développement, c'est normal d'utiliser des données du token
        // Ne logger qu'en mode debug pour éviter le spam
        if (process.env.DEBUG === 'true') {
          logger.info('[DEV] Utilisation des données du token (utilisateur non trouvé en DB)');
        }
        user = {
          id: req.user.id,
          email: req.user.email,
          firstName: req.user.firstName || 'Admin',
          lastName: req.user.lastName || 'User',
          phone: req.user.phone || null,
          profilePicture: req.user.profilePicture || null,
          role: req.user.role || 'ADMIN',
          isActive: true,
          createdAt: new Date(),
          updatedAt: new Date()
        };
      } else {
        return res.status(404).json({
          success: false,
          error: 'Utilisateur non trouvé'
        });
      }
    }

    res.json({
      success: true,
      user
    });
  } catch (error) {
    logger.error('Erreur récupération profil:', error);
    next(error);
  }
};

const refreshToken = async (req, res, next) => {
  try {
    const { refreshToken } = req.body;
    
    if (!refreshToken) {
      return res.status(400).json({
        success: false,
        error: 'Refresh token requis'
      });
    }

    try {
      const decoded = jwt.verify(refreshToken, process.env.JWT_REFRESH_SECRET || process.env.JWT_SECRET);
      
      const user = await prisma.user.findUnique({
        where: { id: decoded.userId }
      });

      if (!user) {
        return res.status(401).json({
          success: false,
          error: 'Utilisateur non trouvé'
        });
      }

      const newToken = jwt.sign(
        { 
          userId: user.id, 
          email: user.email,
          role: user.role || 'USER' // Rôle de l'utilisateur
        },
        process.env.JWT_SECRET,
        { expiresIn: '7d' }
      );

      res.json({
        success: true,
        message: 'Token rafraîchi avec succès',
        token: newToken
      });

    } catch (error) {
      return res.status(401).json({
        success: false,
        error: 'Refresh token invalide'
      });
    }
  } catch (error) {
    logger.error('Erreur refresh token:', error);
    next(error);
  }
};

const logout = async (req, res, next) => {
  try {
    // ✅ Supprimer le cookie de token
    res.clearCookie('token', {
      httpOnly: false,
      secure: false,
      sameSite: 'lax',
      path: '/'
    });

    res.json({
      success: true,
      message: 'Déconnexion réussie'
    });

    logger.info('Utilisateur déconnecté');
  } catch (error) {
    logger.error('Erreur logout:', error);
    next(error);
  }
};

// ✅ ADMIN - Liste tous les utilisateurs
const getAllUsers = async (req, res, next) => {
  try {
    let users = [];
    let totalCount = 0;
    
    try {
      // Récupérer les utilisateurs (filtre optionnel isTestData: true | false)
      const isTestFilter = req.query.isTestData;
      const searchRaw = String(req.query.search || req.query.q || '').trim();
      const limitRaw = parseInt(String(req.query.limit ?? '50'), 10);
      const offsetRaw = parseInt(String(req.query.offset ?? '0'), 10);
      const limit = Number.isNaN(limitRaw) ? 50 : Math.min(Math.max(limitRaw, 1), 200);
      const offset = Number.isNaN(offsetRaw) ? 0 : Math.max(offsetRaw, 0);

      const where = { deletedAt: null };
      if (isTestFilter === 'true') where.isTestData = true;
      else if (isTestFilter === 'false') where.isTestData = false;

      if (searchRaw) {
        where.OR = [
          { email: { contains: searchRaw, mode: 'insensitive' } },
          { firstName: { contains: searchRaw, mode: 'insensitive' } },
          { lastName: { contains: searchRaw, mode: 'insensitive' } }
        ];
        const roleGuess = searchRaw.toUpperCase().replace(/\s+/g, '_');
        if (['USER', 'ADMIN', 'SUPER_ADMIN'].includes(roleGuess)) {
          where.OR.push({ role: roleGuess });
        }
      }

      const selectFields = {
        id: true,
        email: true,
        firstName: true,
        lastName: true,
        phone: true,
        role: true,
        isActive: true,
        isTestData: true,
        createdAt: true,
        updatedAt: true,
        emailVerified: true,
        lastLoginAt: true,
        jobSearchAgentEnabled: true
      };

      const [foundUsers, count] = await Promise.all([
        prisma.user.findMany({
          where,
          select: selectFields,
          orderBy: [{ lastName: 'asc' }, { firstName: 'asc' }, { email: 'asc' }],
          take: limit,
          skip: offset
        }),
        prisma.user.count({ where })
      ]);
      users = foundUsers;
      totalCount = count;
    } catch (dbError) {
      // Vérifier si l'erreur est liée à une table manquante (P2021 ou message contenant "does not exist")
      const isTableMissing = dbError.code === 'P2021' || 
                            (dbError.message && dbError.message.includes('does not exist')) ||
                            (dbError.message && dbError.message.includes('User') && dbError.message.includes('not exist'));
      
      if (isTableMissing && process.env.NODE_ENV === 'development') {
        logger.warn('Table User non trouvée, retour de l\'utilisateur connecté uniquement. Exécutez: make db-push-all');
        logger.warn(`Erreur Prisma: ${dbError.code || 'N/A'} - ${dbError.message}`);
        // Retourner l'utilisateur connecté comme seul utilisateur
        if (req.user) {
          users = [{
            id: req.user.id,
            email: req.user.email,
            firstName: req.user.firstName || 'Admin',
            lastName: req.user.lastName || 'User',
            phone: req.user.phone || null,
            role: req.user.role || 'ADMIN',
            isActive: true,
            createdAt: new Date(),
            updatedAt: new Date(),
            emailVerified: true,
            lastLoginAt: new Date()
          }];
        } else {
          // Si pas d'utilisateur connecté, retourner un utilisateur mock
          users = [{
            id: 'dev_user_1',
            email: 'admin@jobbingtrack.test',
            firstName: 'Admin',
            lastName: 'User',
            phone: null,
            role: 'ADMIN',
            isActive: true,
            createdAt: new Date(),
            updatedAt: new Date(),
            emailVerified: true,
            lastLoginAt: new Date()
          }];
        }
        totalCount = users.length;
      } else {
        throw dbError;
      }
    }

    // Si aucun utilisateur n'est trouvé mais qu'on a un utilisateur connecté, l'ajouter
    if (users.length === 0 && req.user) {
      logger.warn('Aucun utilisateur trouvé dans la base, ajout de l\'utilisateur connecté');
      users = [{
        id: req.user.id,
        email: req.user.email,
        firstName: req.user.firstName || 'Admin',
        lastName: req.user.lastName || 'User',
        phone: req.user.phone || null,
        role: req.user.role || 'ADMIN',
        isActive: true,
        createdAt: new Date(),
        updatedAt: new Date(),
        emailVerified: true,
        lastLoginAt: new Date()
      }];
    }
    if (totalCount === 0 && users.length > 0) {
      totalCount = users.length;
    }

    logger.info(`[getAllUsers] ${users.length} utilisateurs trouvés (total=${totalCount})`);

    const total = totalCount || users.length;
    const limit = Math.min(parseInt(String(req.query.limit ?? '50'), 10) || 50, 200);
    const offset = Math.max(parseInt(String(req.query.offset ?? '0'), 10) || 0, 0);

    res.json({
      success: true,
      users,
      total,
      pagination: {
        total,
        limit,
        offset,
        pages: Math.ceil(total / limit) || 1
      }
    });
  } catch (error) {
    logger.error('Erreur récupération utilisateurs:', error);
    logger.error(`Code erreur: ${error.code}, Message: ${error.message}`);
    
    // Vérifier si l'erreur est liée à une table manquante
    const isTableMissing = error.code === 'P2021' || 
                          (error.message && error.message.includes('does not exist')) ||
                          (error.message && error.message.includes('User') && error.message.includes('not exist'));
    
    // En cas d'erreur, retourner au moins l'utilisateur connecté si disponible
    if (isTableMissing && process.env.NODE_ENV === 'development') {
      logger.warn('Erreur récupération utilisateurs (table manquante), retour de l\'utilisateur connecté uniquement');
      if (req.user) {
        return res.json({
          success: true,
          users: [{
            id: req.user.id,
            email: req.user.email,
            firstName: req.user.firstName || 'Admin',
            lastName: req.user.lastName || 'User',
            phone: req.user.phone || null,
            role: req.user.role || 'ADMIN',
            isActive: true,
            createdAt: new Date(),
            updatedAt: new Date(),
            emailVerified: true,
            lastLoginAt: new Date()
          }],
          total: 1
        });
      } else {
        // Si pas d'utilisateur connecté, retourner un utilisateur mock
        return res.json({
          success: true,
          users: [{
            id: 'dev_user_1',
            email: 'admin@jobbingtrack.test',
            firstName: 'Admin',
            lastName: 'User',
            phone: null,
            role: 'ADMIN',
            isActive: true,
            createdAt: new Date(),
            updatedAt: new Date(),
            emailVerified: true,
            lastLoginAt: new Date()
          }],
          total: 1
        });
      }
    }
    
    // Si ce n'est pas une erreur de table manquante, passer à l'erreur handler
    res.status(500).json({
      success: false,
      error: 'Erreur lors de la récupération des utilisateurs',
      details: process.env.NODE_ENV === 'development' ? error.message : undefined
    });
  }
};

// ✅ ADMIN - Modifier le rôle d'un utilisateur
const updateUserRole = async (req, res, next) => {
  try {
    const { id } = req.params;
    const { role } = req.body;

    if (!['USER', 'ADMIN', 'SUPER_ADMIN'].includes(role)) {
      return res.status(400).json({
        success: false,
        error: 'Rôle invalide'
      });
    }

    const previousUser = await prisma.user.findUnique({
      where: { id },
      select: { role: true, email: true },
    });

    const user = await prisma.user.update({
      where: { id },
      data: { role },
      select: {
        id: true,
        email: true,
        firstName: true,
        lastName: true,
        role: true
      }
    });

    res.json({
      success: true,
      message: 'Rôle mis à jour',
      user
    });

    await sendSecurityLog('info', 'user_administration', 'role_change', `Rôle modifié: ${previousUser?.email || id}`, {
      userId: id,
      sourceIP: req.ip,
      endpoint: req.originalUrl,
      method: req.method,
      userAgent: req.get('user-agent'),
      requestId: req.requestId || req.headers['x-request-id'],
      metadata: {
        previousRole: previousUser?.role ?? null,
        newRole: role,
        actorId: req.user?.id ?? null,
        actorEmail: req.user?.email ?? null,
      },
    });

    logger.info(`Rôle utilisateur modifié: ${id} -> ${role}`);
  } catch (error) {
    logger.error('Erreur mise à jour rôle:', error);
    next(error);
  }
};

// ✅ ADMIN - Activer/Désactiver un utilisateur
const toggleUserStatus = async (req, res, next) => {
  try {
    const role = req.user?.role;
    if (role !== 'ADMIN' && role !== 'SUPER_ADMIN') {
      return res.status(403).json({
        success: false,
        error: 'Accès administrateur requis',
      });
    }

    const { id } = req.params;
    const { isActive } = req.body;

    if (typeof isActive !== 'boolean') {
      return res.status(400).json({
        success: false,
        error: 'Le champ isActive (boolean) est requis',
      });
    }

    if (req.user.id === id && !isActive) {
      return res.status(400).json({
        success: false,
        error: 'Vous ne pouvez pas désactiver votre propre compte',
      });
    }

    const user = await prisma.user.update({
      where: { id },
      data: { isActive },
      select: {
        id: true,
        email: true,
        firstName: true,
        lastName: true,
        isActive: true
      }
    });

    res.json({
      success: true,
      message: `Utilisateur ${isActive ? 'activé' : 'désactivé'}`,
      user
    });

    logger.info(`Statut utilisateur modifié: ${id} -> ${isActive}`);
  } catch (error) {
    logger.error('Erreur modification statut:', error);
    next(error);
  }
};

// ✅ ADMIN - Supprimer un utilisateur
const deleteUser = async (req, res, next) => {
  try {
    const { id } = req.params;

    await prisma.user.delete({
      where: { id }
    });

    res.json({
      success: true,
      message: 'Utilisateur supprimé'
    });

    logger.info(`Utilisateur supprimé: ${id}`);
  } catch (error) {
    if (error.code === 'P2025') {
      return res.status(404).json({
        success: false,
        error: 'Utilisateur non trouvé'
      });
    }
    logger.error('Erreur suppression utilisateur:', error);
    next(error);
  }
};

/**
 * Emails jamais supprimés par cleanTestUsers (admin + comptes porteur .env).
 */
function buildProtectedUserEmails() {
  const emails = new Set();
  const add = (value) => {
    const v = String(value || '').trim().toLowerCase();
    if (v) emails.add(v);
  };
  add(process.env.ADMIN_EMAIL);
  add(process.env.TEST_ADMIN_EMAIL);
  add(process.env.TEST_USER_EMAIL);
  for (const part of String(process.env.PROTECTED_USER_EMAILS || '').split(',')) {
    add(part);
  }
  return emails;
}

function isDisposableSmokeUser(user) {
  const email = String(user.email || '').toLowerCase();
  if (user.isTestData) return true;
  if (email.endsWith('@jobbingtrack.test')) return true;
  if (email.endsWith('@mailhog.local')) return true;
  if (email.endsWith('@example.com')) return true;
  if (email.endsWith('@test.com')) return true;
  if (/^test\+mob/i.test(email)) return true;
  if (/^test\+e2e/i.test(email)) return true;
  if (/^test\+api/i.test(email)) return true;
  if (/^e2e-/i.test(email)) return true;
  if (/^mob-/i.test(email)) return true;
  if (/^verify-/i.test(email)) return true;
  if (email.includes('+mob') && email.includes('@delhomme.ovh')) return true;
  const fn = user.firstName || '';
  const ln = user.lastName || '';
  if ((fn === 'Porteur' || fn === 'Porteur2') && ln === 'Auto') return true;
  if (email === 'candidatures@delhomme.ovh') return true;
  return false;
}

/**
 * Nettoyer les utilisateurs de test / smoke inscription. ADMIN uniquement.
 * Conserve ADMIN_EMAIL, TEST_* et PROTECTED_USER_EMAILS ; ne supprime pas l'utilisateur connecté.
 */
const cleanTestUsers = async (req, res, next) => {
  try {
    const currentUserId = req.user?.id || req.user?.userId;
    const protectedEmails = buildProtectedUserEmails();

    const candidates = await prisma.user.findMany({
      where: {
        deletedAt: null,
        ...(currentUserId ? { id: { not: currentUserId } } : {}),
      },
      select: {
        id: true,
        email: true,
        isTestData: true,
        firstName: true,
        lastName: true,
      },
    });

    const idsToDelete = candidates
      .filter((u) => {
        const email = String(u.email || '').toLowerCase();
        if (protectedEmails.has(email)) return false;
        return isDisposableSmokeUser(u);
      })
      .map((u) => u.id);

    const result = idsToDelete.length
      ? await prisma.user.deleteMany({ where: { id: { in: idsToDelete } } })
      : { count: 0 };

    logger.info(`[cleanTestUsers] ${result.count} utilisateur(s) smoke/test supprimé(s)`);
    res.json({
      success: true,
      message: `${result.count} utilisateur(s) de test supprimé(s)`,
      deletedCount: result.count,
      remainingHint: 'Comptes conservés : admin et TEST_USER_EMAIL / PROTECTED_USER_EMAILS',
    });
  } catch (error) {
    logger.error('Erreur nettoyage utilisateurs de test:', error);
    next(error);
  }
};

// Fonctionnalités de réinitialisation de mot de passe
const hasPasswordResetTokenTable = () => Boolean(prisma.passwordResetToken);

const storePasswordResetToken = async (userId, hashedToken, expiresAt) => {
  if (hasPasswordResetTokenTable()) {
    await prisma.passwordResetToken.deleteMany({
      where: { userId }
    });
    await prisma.passwordResetToken.create({
      data: {
        userId,
        token: hashedToken,
        expiresAt
      }
    });
    return;
  }

  await prisma.user.update({
    where: { id: userId },
    data: {
      resetToken: hashedToken,
      resetTokenExpiry: expiresAt
    }
  });
};

const findValidPasswordResetToken = async (hashedToken, includeFullUser = false) => {
  if (hasPasswordResetTokenTable()) {
    return prisma.passwordResetToken.findFirst({
      where: {
        token: hashedToken,
        used: false,
        expiresAt: {
          gt: new Date()
        }
      },
      include: {
        user: includeFullUser
          ? true
          : {
              select: {
                id: true,
                email: true,
                firstName: true,
                lastName: true
              }
            }
      }
    });
  }

  const user = await prisma.user.findFirst({
    where: {
      resetToken: hashedToken,
      resetTokenExpiry: {
        gt: new Date()
      }
    }
  });

  if (!user) return null;

  return {
    id: `user-reset-token:${user.id}`,
    userId: user.id,
    user
  };
};

const markPasswordResetTokenUsed = async (resetToken) => {
  if (hasPasswordResetTokenTable()) {
    await prisma.passwordResetToken.update({
      where: { id: resetToken.id },
      data: { used: true }
    });
  }
};

const forgotPassword = async (req, res, next) => {
  try {
    const { email } = req.body;

    if (!email) {
      return res.status(400).json({
        success: false,
        error: 'Adresse email requise'
      });
    }

    // Trouver l'utilisateur (version temporaire pour contourner le problème de schéma)
    let user;
    try {
      user = await findUserByLoginEmail(email);
    } catch (schemaError) {
      // Si erreur de schéma, retourner un utilisateur mock pour le développement
      if (schemaError.code === 'P2022' && schemaError.meta?.column?.includes('roles')) {
        console.log('⚠️ Erreur de schéma détectée, utilisation du mode développement');
        user = {
          id: 'dev_user_1',
          email: email.toLowerCase(),
          password: '$2b$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi',
          firstName: 'Dev',
          lastName: 'User',
          role: 'USER'
        };
      } else {
        throw schemaError;
      }
    }

    if (!user) {
      // Pour des raisons de sécurité, retourner le même message
      return res.json({
        success: true,
        message: 'Si cette adresse email existe, un lien de réinitialisation a été envoyé'
      });
    }

    // Générer un token sécurisé
    const resetToken = crypto.randomBytes(32).toString('hex');
    const hashedToken = crypto.createHash('sha256').update(resetToken).digest('hex');

    // Définir l'expiration (1 heure)
    const expiresAt = new Date(Date.now() + 60 * 60 * 1000);

    await storePasswordResetToken(user.id, hashedToken, expiresAt);

    // Envoyer l'email avec le token non hashé
    // Le service attend maintenant un resetToken, pas une URL complète
    try {
      await emailService.sendPasswordResetEmail(user, resetToken);
    } catch (emailError) {
      logger.error('Erreur envoi email réinitialisation:', emailError);
      // Ne pas échouer complètement si l'email échoue
      return res.status(500).json({
        success: false,
        error: 'Erreur lors de l\'envoi de l\'email de réinitialisation',
        details: process.env.NODE_ENV === 'development' ? emailError.message : undefined
      });
    }

    res.json({
      success: true,
      message: 'Lien de réinitialisation envoyé par email'
    });

    logger.info(`Demande de réinitialisation de mot de passe pour: ${user.email}`);
  } catch (error) {
    logger.error('Erreur demande réinitialisation:', error);
    
    // Gestion d'erreur améliorée pour les erreurs de base de données
    if (error.code === 'P2021' || (error.message && error.message.includes('does not exist'))) {
      logger.warn('Table PasswordResetToken non trouvée, tentative d\'envoi d\'email sans token en DB');
      // Essayer d'envoyer l'email quand même si l'utilisateur existe
      if (user) {
        try {
          const resetToken = crypto.randomBytes(32).toString('hex');
          await emailService.sendPasswordResetEmail(user, resetToken);
          return res.json({
            success: true,
            message: 'Lien de réinitialisation envoyé par email (mode développement)'
          });
        } catch (emailError) {
          logger.error('Erreur envoi email:', emailError);
        }
      }
    }
    
    res.status(500).json({
      success: false,
      error: 'Erreur lors de la demande de réinitialisation',
      details: process.env.NODE_ENV === 'development' ? error.message : undefined
    });
  }
};

const verifyResetToken = async (req, res, next) => {
  try {
    const { token } = req.params;

    if (!token) {
      return res.status(400).json({
        success: false,
        error: 'Token requis'
      });
    }

    // Hasher le token reçu pour comparaison
    const hashedToken = crypto.createHash('sha256').update(token).digest('hex');

    // Trouver le token dans la base de données
    const resetToken = await findValidPasswordResetToken(hashedToken);

    if (!resetToken) {
      return res.status(400).json({
        success: false,
        error: 'Token invalide ou expiré'
      });
    }

    res.json({
      success: true,
      message: 'Token valide',
      email: resetToken.user.email
    });
  } catch (error) {
    logger.error('Erreur vérification token:', error);
    next(error);
  }
};

// ✅ ADMIN - Envoyer un email de réinitialisation de mot de passe pour un utilisateur spécifique
const sendPasswordResetForUser = async (req, res, next) => {
  try {
    const { id } = req.params;

    // Vérifier que l'utilisateur existe
    const user = await prisma.user.findUnique({
      where: { id },
      select: {
        id: true,
        email: true,
        firstName: true,
        lastName: true,
        isActive: true
      }
    });

    if (!user) {
      return res.status(404).json({
        success: false,
        error: 'Utilisateur non trouvé'
      });
    }

    if (!user.isActive) {
      return res.status(400).json({
        success: false,
        error: 'Cet utilisateur est désactivé'
      });
    }

    // Générer un token sécurisé
    const resetToken = crypto.randomBytes(32).toString('hex');
    const hashedToken = crypto.createHash('sha256').update(resetToken).digest('hex');

    // Définir l'expiration (1 heure)
    const expiresAt = new Date(Date.now() + 60 * 60 * 1000);

    await storePasswordResetToken(user.id, hashedToken, expiresAt);

    // Envoyer l'email avec le token non hashé
    try {
      await emailService.sendPasswordResetEmail(user, resetToken);
    } catch (emailError) {
      logger.error('Erreur envoi email réinitialisation:', emailError);
      // Ne pas échouer complètement si l'email échoue
      return res.status(500).json({
        success: false,
        error: 'Erreur lors de l\'envoi de l\'email de réinitialisation',
        details: process.env.NODE_ENV === 'development' ? emailError.message : undefined
      });
    }

    res.json({
      success: true,
      message: `Email de réinitialisation de mot de passe envoyé à ${user.email}`
    });

    logger.info(`Email de réinitialisation envoyé par admin pour: ${user.email}`);
  } catch (error) {
    logger.error('Erreur envoi email réinitialisation (admin):', error);
    next(error);
  }
};

const resetPassword = async (req, res, next) => {
  try {
    const { token } = req.params;
    const { password } = req.body;

    if (!token || !password) {
      return res.status(400).json({
        success: false,
        error: 'Token et mot de passe requis'
      });
    }

    if (password.length < 6) {
      return res.status(400).json({
        success: false,
        error: 'Le mot de passe doit contenir au moins 6 caractères'
      });
    }

    // Hasher le token reçu
    const hashedToken = crypto.createHash('sha256').update(token).digest('hex');

    // Trouver le token valide
    const resetToken = await findValidPasswordResetToken(hashedToken, true);

    if (!resetToken) {
      return res.status(400).json({
        success: false,
        error: 'Token invalide ou expiré'
      });
    }

    // Hasher le nouveau mot de passe
    const hashedPassword = await bcrypt.hash(password, 12);

    // Mettre à jour le mot de passe de l'utilisateur
    await prisma.user.update({
      where: { id: resetToken.userId },
      data: {
        password: hashedPassword,
        // Nettoyer les anciens tokens de reset
        resetToken: null,
        resetTokenExpiry: null
      }
    });

    // Marquer le token comme utilisé si une table dédiée existe.
    // Sinon, les colonnes User.resetToken/resetTokenExpiry sont déjà nettoyées ci-dessus.
    await markPasswordResetTokenUsed(resetToken);

    // Envoyer un email de confirmation de changement de mot de passe
    emailService.sendPasswordChangedEmail(resetToken.user).catch(error => {
      logger.error('Erreur envoi email confirmation changement mot de passe:', error);
      // Ne pas faire échouer la requête si l'email échoue
    });

    res.json({
      success: true,
      message: 'Mot de passe réinitialisé avec succès'
    });

    logger.info(`Mot de passe réinitialisé pour: ${resetToken.user.email}`);
  } catch (error) {
    logger.error('Erreur réinitialisation mot de passe:', error);
    next(error);
  }
};

// ✅ CUSTOMIZATION - Gestion de la personnalisation utilisateur
const getUserCustomization = async (req, res) => {
  try {
    const userId = req.user.id;

    // Utiliser upsert pour éviter duplicate key si deux requêtes simultanées
    let customization;
    try {
      customization = await prisma.userCustomization.upsert({
        where: { userId },
        update: {},
        create: {
          userId,
          settings: {
            theme: 'auto',
            language: 'fr',
            dashboardLayout: 'grid',
            primaryColor: '#3B82F6',
            accentColor: '#10B981',
            sidebarCollapsed: false,
            compactMode: false,
            showAnimations: true,
            itemsPerPage: 20,
            autoRefresh: true,
            refreshInterval: 30,
            notifications: {
              enabled: true,
              sound: true,
              position: 'top-right',
              duration: 5000
            },
            accessibility: {
              highContrast: false,
              largeText: false,
              reduceMotion: false,
              focusIndicators: true
            },
            dataRetention: {
              cacheDuration: 7,
              syncFrequency: 5,
              offlineMode: true
            }
          }
        }
      });
    } catch (upsertError) {
      if (upsertError.code === 'P2002') {
        customization = await prisma.userCustomization.findUnique({
          where: { userId }
        });
        if (!customization) throw upsertError;
      } else {
        throw upsertError;
      }
    }

    res.json({
      success: true,
      data: customization.settings
    });

  } catch (error) {
    logger.error('Erreur lors de la récupération des paramètres de personnalisation:', error);
    res.status(500).json({
      success: false,
      message: 'Erreur lors de la récupération des paramètres de personnalisation'
    });
  }
};

const saveUserCustomization = async (req, res) => {
  try {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({
        success: false,
        errors: errors.array()
      });
    }

    const userId = req.user.id;
    const customizationData = req.body;

    const customization = await prisma.userCustomization.upsert({
      where: { userId },
      update: {
        settings: customizationData,
        updatedAt: new Date()
      },
      create: {
        userId,
        settings: customizationData
      }
    });

    res.json({
      success: true,
      data: customization.settings,
      message: 'Paramètres de personnalisation sauvegardés avec succès'
    });

  } catch (error) {
    logger.error('Erreur lors de la sauvegarde des paramètres de personnalisation:', error);
    res.status(500).json({
      success: false,
      message: 'Erreur lors de la sauvegarde des paramètres de personnalisation'
    });
  }
};

// Fonction pour envoyer les logs de sécurité au security-service
async function sendSecurityLog(level, category, eventType, message, additionalData = {}) {
  try {
    const axios = require('axios');
    const securityServiceUrl = (
      process.env.SECURITY_SERVICE_URL || 'http://jobbingtrack-security-service:3017'
    ).replace(/\/$/, '');
    const internalSecret = process.env.SECURITY_INTERNAL_SECRET;
    if (!internalSecret) return Promise.resolve();

    const loginActionMap = {
      login_success: 'admin_login_success',
      login_failure: 'admin_login_failure',
      login_email_not_verified: 'admin_login_failure',
      registration_success: 'admin_registration_success',
      registration_validation_error: 'admin_registration_failure',
      role_change: 'role_change',
    };
    const action =
      loginActionMap[eventType] ||
      `security_${String(eventType || 'event').replace(/[^a-z0-9_]+/gi, '_').toLowerCase()}`;
    const outcome =
      String(level).toLowerCase().includes('warn') ||
      String(level).toLowerCase().includes('error') ||
      String(eventType).includes('failure')
        ? 'failure'
        : 'success';

    await axios.post(
      `${securityServiceUrl}/api/v1/security/audit/events`,
      {
        action,
        resource: category || 'authentication',
        resourceId: additionalData.userId || additionalData.metadata?.userId || null,
        outcome,
        clientIp: additionalData.sourceIP || additionalData.ip || null,
        metadata: {
          eventType,
          message,
          level,
          category,
          endpoint: additionalData.endpoint,
          method: additionalData.method,
          userAgent: additionalData.userAgent,
          ...additionalData.metadata,
        },
      },
      {
        timeout: 2000,
        headers: {
          'Content-Type': 'application/json',
          'X-Internal-Secret': internalSecret,
          ...(additionalData.requestId
            ? { 'X-Request-Id': String(additionalData.requestId) }
            : {}),
        },
      }
    );
  } catch {
    // Non bloquant — l’auth ne doit pas échouer si l’audit est indisponible
  }
  return Promise.resolve();
}

// Déplacer getActiveSessions et getSecurityMetrics en dehors du scope
const getActiveSessions = async (req, res, next) => {
  try {
    let activeUsers = [];
    
    try {
      // ✅ Récupérer les utilisateurs connectés dans les dernières 30 minutes
      const thirtyMinutesAgo = new Date(Date.now() - 30 * 60 * 1000);
      
      activeUsers = await prisma.user.findMany({
        where: {
          lastLoginAt: {
            gte: thirtyMinutesAgo
          },
          isActive: true
        },
        select: {
          id: true,
          email: true,
          firstName: true,
          lastName: true,
          role: true,
          lastLoginAt: true
        },
        orderBy: {
          lastLoginAt: 'desc'
        }
      });
    } catch (dbError) {
      // Vérifier si l'erreur est liée à une table manquante
      const isTableMissing = dbError.code === 'P2021' || 
                            (dbError.message && dbError.message.includes('does not exist')) ||
                            (dbError.message && dbError.message.includes('User') && dbError.message.includes('not exist'));
      
      // Si la table User n'existe pas, retourner l'utilisateur connecté en développement
      if (isTableMissing && process.env.NODE_ENV === 'development') {
        logger.warn('Table User non trouvée, retour de l\'utilisateur connecté uniquement. Exécutez: make db-push-all');
        // Retourner l'utilisateur connecté comme session active
        if (req.user) {
          activeUsers = [{
            id: req.user.id,
            email: req.user.email,
            firstName: req.user.firstName || 'Admin',
            lastName: req.user.lastName || 'User',
            role: req.user.role || 'ADMIN',
            lastLoginAt: new Date()
          }];
        } else {
          // Si pas d'utilisateur connecté, retourner une session mock
          activeUsers = [{
            id: 'dev_user_1',
            email: 'admin@jobbingtrack.test',
            firstName: 'Admin',
            lastName: 'User',
            role: 'ADMIN',
            lastLoginAt: new Date()
          }];
        }
      } else {
        throw dbError;
      }
    }

    // Si aucun utilisateur actif n'est trouvé mais qu'on a un utilisateur connecté, l'ajouter
    if (activeUsers.length === 0 && req.user) {
      logger.warn('Aucune session active trouvée, ajout de l\'utilisateur connecté');
      activeUsers = [{
        id: req.user.id,
        email: req.user.email,
        firstName: req.user.firstName || 'Admin',
        lastName: req.user.lastName || 'User',
        role: req.user.role || 'ADMIN',
        lastLoginAt: new Date()
      }];
    }

    // Formater les sessions pour l'affichage
    const activeSessions = activeUsers.map(user => ({
      id: user.id,
      userId: user.id,
      userEmail: user.email,
      userName: `${user.firstName} ${user.lastName}`,
      userRole: user.role,
      lastActivity: user.lastLoginAt,
      createdAt: user.lastLoginAt
    }));

    res.json({
      success: true,
      sessions: activeSessions,
      total: activeSessions.length,
      timestamp: new Date().toISOString(),
      activeUsersLast30Min: activeSessions.length
    });
  } catch (error) {
    logger.error('Erreur récupération sessions actives:', error);
    logger.error(`Code erreur: ${error.code}, Message: ${error.message}`);
    
    // Vérifier si l'erreur est liée à une table manquante
    const isTableMissing = error.code === 'P2021' || 
                          (error.message && error.message.includes('does not exist')) ||
                          (error.message && error.message.includes('User') && error.message.includes('not exist'));
    
    // En cas d'erreur, retourner au moins l'utilisateur connecté si disponible
    if (isTableMissing && process.env.NODE_ENV === 'development') {
      logger.warn('Erreur récupération sessions actives (table manquante), retour de l\'utilisateur connecté uniquement');
      if (req.user) {
        return res.json({
          success: true,
          sessions: [{
            id: req.user.id,
            userId: req.user.id,
            userEmail: req.user.email,
            userName: `${req.user.firstName || 'Admin'} ${req.user.lastName || 'User'}`,
            userRole: req.user.role || 'ADMIN',
            lastActivity: new Date(),
            createdAt: new Date()
          }],
          total: 1,
          timestamp: new Date().toISOString(),
          activeUsersLast30Min: 1
        });
      } else {
        // Si pas d'utilisateur connecté, retourner une session mock
        return res.json({
          success: true,
          sessions: [{
            id: 'dev_user_1',
            userId: 'dev_user_1',
            userEmail: 'admin@jobbingtrack.test',
            userName: 'Admin User',
            userRole: 'ADMIN',
            lastActivity: new Date(),
            createdAt: new Date()
          }],
          total: 1,
          timestamp: new Date().toISOString(),
          activeUsersLast30Min: 1
        });
      }
    }
    
    // Si ce n'est pas une erreur de table manquante, retourner une erreur 500
    res.status(500).json({
      success: false,
      error: 'Erreur lors de la récupération des sessions actives',
      details: process.env.NODE_ENV === 'development' ? error.message : undefined
    });
  }
};

const getSecurityMetrics = async (req, res, next) => {
  try {
    const metrics = {
      timestamp: new Date().toISOString(),
      authentication: {
        totalLogins: Math.floor(Math.random() * 100) + 50,
        failedLogins: Math.floor(Math.random() * 20),
        successfulLogins: Math.floor(Math.random() * 80) + 30,
        activeSessions: Math.floor(Math.random() * 10) + 5,
        suspiciousActivities: Math.floor(Math.random() * 15)
      },
      vulnerabilities: {
        critical: Math.floor(Math.random() * 3),
        high: Math.floor(Math.random() * 8) + 2,
        medium: Math.floor(Math.random() * 15) + 5,
        low: Math.floor(Math.random() * 25) + 10,
        total: 0
      },
      compliance: {
        owaspScore: 85 + Math.random() * 15,
        gdprCompliance: Math.random() > 0.1 ? 'compliant' : 'non-compliant',
        lastAudit: new Date(Date.now() - Math.random() * 30 * 24 * 60 * 60 * 1000).toISOString()
      }
    };

    metrics.vulnerabilities.total = 
      metrics.vulnerabilities.critical +
      metrics.vulnerabilities.high +
      metrics.vulnerabilities.medium +
      metrics.vulnerabilities.low;

    res.json({
      success: true,
      metrics
    });
  } catch (error) {
    logger.error('Erreur récupération métriques sécurité:', error);
    res.status(500).json({
      success: false,
      error: 'Erreur lors de la récupération des métriques de sécurité'
    });
  }
};

// ✅ Générer un token de test permanent (pour les tests user-journey)
// Réservé aux SUPER_ADMIN uniquement
const generateTestToken = async (req, res) => {
  try {
    // Vérifier que l'utilisateur est SUPER_ADMIN
    const authHeader = req.headers.authorization;
    
    if (!authHeader) {
      return res.status(401).json({
        success: false,
        error: 'Authentification requise'
      });
    }

    const parts = authHeader.split(' ');
    const token = parts[1];

    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    const user = await prisma.user.findUnique({
      where: { id: decoded.userId }
    });

    if (!user || user.role !== 'SUPER_ADMIN') {
      return res.status(403).json({
        success: false,
        error: 'Accès réservé aux super administrateurs'
      });
    }

    // Générer un token de test qui n'expire JAMAIS (ou dans 100 ans)
    const testToken = jwt.sign(
      { 
        userId: user.id, 
        email: user.email,
        role: user.role,
        testToken: true // Marqueur pour identifier un token de test
      },
      process.env.JWT_SECRET,
      { expiresIn: '100y' } // 100 ans = pratiquement permanent
    );

    logger.info(`Token de test permanent généré pour ${user.email}`);

    res.json({
      success: true,
      message: 'Token de test permanent généré',
      testToken,
      expiresIn: '100 ans (permanent)',
      warning: 'Ce token est réservé aux tests. Ne jamais l\'utiliser en production.'
    });

  } catch (error) {
    logger.error('Erreur génération token de test:', error);
    res.status(500).json({
      success: false,
      error: 'Erreur lors de la génération du token de test'
    });
  }
};

// Vérifier l'email avec le token
const verifyEmail = async (req, res, next) => {
  try {
    const { token } = req.params;

    if (!token) {
      return res.status(400).json({
        success: false,
        error: 'Token de vérification requis'
      });
    }

    // Trouver l'utilisateur avec ce token de vérification
    const user = await prisma.user.findFirst({
      where: {
        verificationToken: token,
        verificationTokenExpiry: {
          gt: new Date() // Token pas encore expiré
        },
        emailVerified: false // Pas encore vérifié
      }
    });

    if (!user) {
      await sendSecurityLog('warning', 'authentication', 'email_verification_failed', 'Tentative de vérification avec token invalide ou expiré', {
        sourceIP: req.ip,
        endpoint: req.path,
        method: req.method,
        userAgent: req.get('User-Agent'),
        riskScore: 25,
        metadata: {
          tokenProvided: !!token
        }
      });

      return res.status(400).json({
        success: false,
        error: 'Token de vérification invalide ou expiré. Veuillez demander un nouveau lien de vérification.'
      });
    }

    // Marquer l'email comme vérifié
    const updatedUser = await prisma.user.update({
      where: { id: user.id },
      data: {
        emailVerified: true,
        emailVerifiedAt: new Date(),
        verificationToken: null, // Supprimer le token une fois utilisé
        verificationTokenExpiry: null
      }
    });

    // Log de succès
    await sendSecurityLog('info', 'authentication', 'email_verification_success', 'Email vérifié avec succès', {
      sourceIP: req.ip,
      endpoint: req.path,
      method: req.method,
      userAgent: req.get('User-Agent'),
      userId: user.id,
      riskScore: 0,
      metadata: {
        userEmail: user.email,
        verifiedAt: new Date()
      }
    });

    logger.info(`Email vérifié avec succès pour l'utilisateur: ${user.email}`);

    res.json({
      success: true,
      message: 'Votre adresse email a été vérifiée avec succès ! Vous pouvez maintenant utiliser toutes les fonctionnalités de JobbingTrack.',
      user: {
        id: updatedUser.id,
        email: updatedUser.email,
        firstName: updatedUser.firstName,
        lastName: updatedUser.lastName,
        emailVerified: updatedUser.emailVerified
      }
    });

  } catch (error) {
    logger.error('Erreur vérification email:', error);
    next(error);
  }
};

// Renvoyer l'email de vérification
const resendVerificationEmail = async (req, res, next) => {
  try {
    const { email } = req.body;

    if (!email) {
      return res.status(400).json({
        success: false,
        error: 'Adresse email requise'
      });
    }

    // Trouver l'utilisateur
    const user = await findUserByLoginEmail(email);

    if (!user) {
      // Ne pas révéler si l'utilisateur existe ou non pour la sécurité
      return res.json({
        success: true,
        message: 'Si cette adresse email existe dans notre système, un nouvel email de vérification a été envoyé.'
      });
    }

    // Si l'email est déjà vérifié
    if (user.emailVerified) {
      return res.status(400).json({
        success: false,
        error: 'Cette adresse email est déjà vérifiée.'
      });
    }

    // Générer un nouveau token de vérification
    const verificationToken = crypto.randomBytes(32).toString('hex');
    const verificationTokenExpiry = new Date(Date.now() + 24 * 60 * 60 * 1000); // 24 heures

    // Mettre à jour l'utilisateur avec le nouveau token
    await prisma.user.update({
      where: { id: user.id },
      data: {
        verificationToken,
        verificationTokenExpiry
      }
    });

    // Envoyer l'email de vérification
    // Le service construit maintenant l'URL lui-même
    await emailService.sendVerificationEmail(user, verificationToken);

    // Log de l'action
    await sendSecurityLog('info', 'authentication', 'verification_email_resent', 'Email de vérification renvoyé', {
      sourceIP: req.ip,
      endpoint: req.path,
      method: req.method,
      userAgent: req.get('User-Agent'),
      userId: user.id,
      riskScore: 5,
      metadata: {
        userEmail: user.email
      }
    });

    logger.info(`Email de vérification renvoyé pour: ${user.email}`);

    res.json({
      success: true,
      message: 'Un nouvel email de vérification a été envoyé à votre adresse. Veuillez vérifier votre boîte de réception.'
    });

  } catch (error) {
    logger.error('Erreur renvoi email vérification:', error);
    next(error);
  }
};

const HUBERA_ID_VALIDATE_URLS = [
  'https://id.hubera.cloud/auth/validate',
  'https://api.cloudity.delhomme.ovh/auth/validate',
  'https://mail.hubera.cloud/auth/validate',
];

function huberaOwnerEmails() {
  const out = new Set();
  for (const key of ['ADMIN_EMAIL', 'HUBERA_ID_OWNER', 'HUBERA_ADMIN_EMAIL']) {
    const v = String(process.env[key] || '').trim().toLowerCase();
    if (v) out.add(v);
  }
  out.add('paul@delhomme.ovh');
  return out;
}

async function resolveJobsUserFromHuberaEmail(email) {
  const owners = huberaOwnerEmails();
  let user = await findUserByLoginEmail(email);
  const adminEmail = String(process.env.ADMIN_EMAIL || '').trim().toLowerCase();
  if (!user && owners.has(email) && adminEmail && adminEmail !== email) {
    const admin = await findUserByLoginEmail(adminEmail);
    if (admin) {
      try {
        user = await prisma.user.update({
          where: { id: admin.id },
          data: { email, role: 'SUPER_ADMIN', emailVerified: true, isActive: true },
        });
        logger.info(`Compte Jobs admin ${adminEmail} → ${email} (SSO Hubera ID)`);
      } catch (err) {
        logger.warn(`Impossible de renommer l’admin Jobs: ${err.message}`);
        user = admin;
      }
    }
  }
  if (!user) {
    const role = owners.has(email) ? 'SUPER_ADMIN' : 'USER';
    user = await prisma.user.create({
      data: {
        email,
        password: await bcrypt.hash(crypto.randomBytes(24).toString('hex'), 10),
        firstName: owners.has(email) ? 'Paul' : email.split('@')[0] || 'Hubera',
        lastName: owners.has(email) ? 'Delhomme' : 'ID',
        role,
        isActive: true,
        emailVerified: true,
      },
    });
    logger.info(`Compte Jobs créé via SSO Hubera ID: ${email} (${role})`);
  } else if (owners.has(email) && user.role !== 'SUPER_ADMIN') {
    user = await prisma.user.update({
      where: { id: user.id },
      data: { role: 'SUPER_ADMIN', emailVerified: true, isActive: true },
    });
  }
  return user;
}

const loginHuberaSso = async (req, res, next) => {
  try {
    const token = String(req.body?.access_token || req.body?.accessToken || '').trim();
    if (!token) {
      return res.status(400).json({ success: false, error: 'token requis' });
    }
    let email = '';
    for (const url of HUBERA_ID_VALIDATE_URLS) {
      try {
        const r = await axios.get(url, {
          headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
          timeout: 8000,
          validateStatus: () => true,
        });
        if (r.status < 200 || r.status >= 300) continue;
        email = String(r.data?.email || r.data?.user?.email || '')
          .trim()
          .toLowerCase();
        if (email) break;
      } catch (_) {
        /* hôte suivant */
      }
    }
    if (!email) {
      return res.status(401).json({ success: false, error: 'Jeton Hubera ID invalide ou expiré' });
    }
    const user = await resolveJobsUserFromHuberaEmail(email);
    if (!user) {
      return res.status(401).json({
        success: false,
        error: 'Pas de compte Jobs pour cet e-mail — connexion mot de passe une fois.',
      });
    }
    const jwtToken = jwt.sign(
      { userId: user.id, email: user.email, role: user.role || 'USER' },
      process.env.JWT_SECRET,
      { expiresIn: '7d' }
    );
    const { password: _, resetToken, resetTokenExpiry, ...userWithoutPassword } = user;
    res.cookie('token', jwtToken, {
      httpOnly: false,
      secure: false,
      sameSite: 'lax',
      maxAge: 7 * 24 * 60 * 60 * 1000,
      path: '/',
    });
    res.json({
      success: true,
      message: 'Connexion SSO Hubera ID',
      user: userWithoutPassword,
      token: jwtToken,
      refreshToken: jwt.sign(
        { userId: user.id, type: 'refresh' },
        process.env.JWT_REFRESH_SECRET || process.env.JWT_SECRET,
        { expiresIn: '30d' }
      ),
    });
  } catch (error) {
    logger.error('Erreur SSO Hubera ID:', error);
    next(error);
  }
};

module.exports = {
  register,
  login,
  loginHuberaSso,
  verifyPassword,
  getProfile,
  refreshToken,
  logout,
  getAllUsers,
  cleanTestUsers,
  updateUserRole,
  toggleUserStatus,
  deleteUser,
  forgotPassword,
  sendPasswordResetForUser,
  verifyResetToken,
  resetPassword,
  getUserCustomization,
  saveUserCustomization,
  getActiveSessions,
  getSecurityMetrics,
  generateTestToken,
  verifyEmail,
  resendVerificationEmail
};
