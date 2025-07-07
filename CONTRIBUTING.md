# Contributing to The Greatest

Thank you for your interest in contributing to The Greatest! This document provides guidelines and information for contributors.

## 🚀 Quick Start

1. **Follow the [Development Setup Guide](docs/dev_setup.md)** to get your local environment running
2. **Create a feature branch** from `main`
3. **Make your changes** following the guidelines below
4. **Test thoroughly** across all domains
5. **Submit a pull request**

## 📋 Development Guidelines

### Code Style

- **Ruby**: Follow [Ruby Style Guide](https://github.com/rubocop/ruby-style-guide)
- **Rails**: Follow Rails conventions and best practices
- **JavaScript**: Use modern ES6+ syntax
- **CSS**: Follow Tailwind CSS conventions

### Testing Requirements

- **100% test coverage** for all new code
- **Run tests** before submitting: `cd web-app && bin/rails test`
- **Test all domains** to ensure changes work across music, movies, and games
- **Use fixtures** instead of creating data in tests (see [testing guide](docs/testing.md))

### Multi-Domain Considerations

- **Test changes** on all domains (music, movies, games)
- **Domain-specific code** should be properly namespaced
- **Shared functionality** should work across all domains
- **CSS changes** should not bleed between domains

### Documentation

- **Update documentation** for any new features or changes
- **Follow the documentation standards** in [docs/documentation.md](docs/documentation.md)
- **Add class documentation** for new models, services, or controllers

## 🏗️ Architecture Principles

### Domain-Driven Design
- **Media-specific modules** must be namespaced (e.g., `Books::`, `Movies::`, `Music::`, `Games::`)
- **Shared functionality** goes in the global namespace
- **Clear boundaries** between domain-specific and shared code

### Database Design
- **Human-readable URLs** using FriendlyId
- **Polymorphic relationships** for shared functionality
- **Consistent naming** with `_able` suffix for polymorphic associations

### Service Objects
- **Extract business logic** into service objects
- **Use the Result pattern** for consistent success/failure responses
- **Single responsibility** per service

## 🐛 Bug Reports

When reporting bugs, please include:

1. **Domain affected** (music, movies, games, or all)
2. **Steps to reproduce** the issue
3. **Expected behavior** vs actual behavior
4. **Environment details** (browser, OS, etc.)
5. **Screenshots** if applicable

## 💡 Feature Requests

For feature requests:

1. **Check existing issues** to avoid duplicates
2. **Describe the feature** clearly and concisely
3. **Explain the benefit** to users
4. **Consider multi-domain impact** (should it work on all domains?)

## 🔄 Pull Request Process

1. **Create a feature branch** from `main`
2. **Make focused changes** - one feature or fix per PR
3. **Write clear commit messages** following conventional commits
4. **Update documentation** as needed
5. **Test thoroughly** across all domains
6. **Ensure all tests pass**
7. **Submit the PR** with a clear description

### PR Description Template

```markdown
## Summary
Brief description of changes

## Changes Made
- [ ] Change 1
- [ ] Change 2
- [ ] Change 3

## Testing
- [ ] Tests pass: `bin/rails test`
- [ ] Tested on music domain
- [ ] Tested on movies domain  
- [ ] Tested on games domain
- [ ] Documentation updated

## Screenshots
[If applicable]

## Related Issues
Closes #123
```

## 📚 Resources

- **[Development Setup](docs/dev_setup.md)** - Complete local development guide
- **[Testing Guide](docs/testing.md)** - Testing standards and practices
- **[Documentation Guide](docs/documentation.md)** - Documentation standards
- **[Core Values](docs/dev-core-values.md)** - Development principles and standards
- **[Project Summary](docs/summary.md)** - High-level project overview

## 🤝 Questions?

- **Setup issues**: Check the [development setup guide](docs/dev_setup.md)
- **Architecture questions**: Review [core values](docs/dev-core-values.md) and [project summary](docs/summary.md)
- **General questions**: Open an issue or reach out to the maintainers

Thank you for contributing to The Greatest! 🎵🎬🎮 