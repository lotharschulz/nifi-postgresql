# GitHub Copilot Agents

This project includes specialized AI agents to help with different aspects of the Apache NiFi & PostgreSQL CDC/Outbox pattern implementation.

## Available Agents

### @setup-agent
**Purpose:** Expert in NiFi automation and bash scripting  
**Use for:**
- Writing/fixing NiFi REST API setup scripts
- Adding error handling and retry logic
- Implementing dry-run modes
- Debugging bash script issues

**Example usage:**
```
@setup-agent add retry logic to the processor configuration function
@setup-agent fix the dry-run mode in nifi-cdc-setup.sh
@setup-agent add validation for environment variables
```

### @docs-agent
**Purpose:** Technical documentation writer  
**Use for:**
- Writing setup instructions
- Documenting CDC and Outbox patterns
- Creating troubleshooting guides
- Explaining architecture and workflows

**Example usage:**
```
@docs-agent write a troubleshooting section for README.md
@docs-agent explain the Outbox pattern with examples
@docs-agent document all environment variables
```

### @docker-agent
**Purpose:** Docker and container infrastructure specialist  
**Use for:**
- Configuring docker-compose.yml
- Adding health checks
- Setting up volume mounts
- Troubleshooting container issues

**Example usage:**
```
@docker-agent add health checks to PostgreSQL service
@docker-agent configure memory limits for NiFi
@docker-agent fix the JDBC driver mount issue
```

### @sql-agent
**Purpose:** PostgreSQL and CDC schema expert  
**Use for:**
- Writing SQL schemas
- Creating triggers for Outbox pattern
- Configuring logical replication
- Optimizing CDC queries

**Example usage:**
```
@sql-agent create an outbox table with proper indexes
@sql-agent add a trigger to capture order events
@sql-agent write a query to check replication lag
```

## How Agents Work

Each agent has:
1. **Specific expertise** - Deep knowledge in one area
2. **Project context** - Understanding of this codebase's structure
3. **Commands** - Tools they can run to validate their work
4. **Code patterns** - Examples of good vs bad practices
5. **Clear boundaries** - What they should and shouldn't modify

## Best Practices

### When to use agents
- **Use specific agents** for focused tasks: `@setup-agent` for scripts, `@docs-agent` for docs
- **Use multiple agents** for complex work: `@sql-agent` designs schema, then `@docs-agent` documents it
- **Start conversations** with the right agent to get expert-level assistance immediately

### What agents won't do
- Commit sensitive credentials (all agents check for this)
- Make destructive changes without confirmation
- Modify files outside their domain
- Remove error handling or safety checks

## Agent Design Principles

Following [GitHub's best practices](https://github.blog/ai-and-ml/github-copilot/how-to-write-a-great-agents-md-lessons-from-over-2500-repositories/):

✅ **Commands early** - Each agent lists executable commands first  
✅ **Code examples** - Shows good vs bad patterns with actual code  
✅ **Clear boundaries** - Always/Ask/Never rules prevent mistakes  
✅ **Specific stack** - Exact versions: NiFi 1.24.0, PostgreSQL 15  
✅ **Six core areas** - Commands, testing, structure, style, git, boundaries  

## Extending Agents

To modify an agent:
1. Edit the relevant `.github/agents/*.md` file
2. Update persona, commands, or boundaries
3. Test with a simple request to verify behavior

To add a new agent:
1. Create `.github/agents/new-agent.md`
2. Include YAML frontmatter with name/description
3. Follow the template structure from existing agents
4. Document in this README

## Learn More

- [GitHub Blog: How to write a great agents.md](https://github.blog/ai-and-ml/github-copilot/how-to-write-a-great-agents-md-lessons-from-over-2500-repositories/)
- [GitHub Copilot Documentation](https://docs.github.com/en/copilot)
